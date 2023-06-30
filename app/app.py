#!/usr/bin/env python3
from flask import (
    Flask,
    render_template,
    request,
    redirect,
    Blueprint,
    make_response,
    url_for,
)
from flask_restx import Resource, Api, Namespace, fields
import time
import os
import uuid
import sqlite3
from pprint import pprint
import json
import argparse


from app import config
from app.payments import database
from app.node.qrl import coingecko
from app.node import qrld
from app.gateways import woo_webhook

app = Flask(__name__)

# Load a qrlPay API key or create a new one
if os.path.exists("qrlPay_API_key"):
    with open("qrlPay_API_key", "r") as f:
        app.config["SECRET_KEY"] = f.read().strip()
else:
    with open("qrlPay_API_key", "w") as f:
        app.config["SECRET_KEY"] = os.urandom(64).hex()
        f.write(app.config["SECRET_KEY"])

print("[qrlPay api-key] : {}\n".format(app.config["SECRET_KEY"]))

# Create payment database if it does not exist
if not os.path.exists("database.db"):
    database.create_database()


# Render index page
# This is currently a donation page that submits to /pay
@app.route("/")
def index():
    headers = {"Content-Type": "text/html"}
    return make_response(render_template("donate.html"), 200, headers)


# /pay is the main page for initiating a payment, takes a GET request with ?amount=
@app.route("/pay")
def pay():
    params = dict(request.args)
    if "redirect" in params:
        params["redirect"] = params["redirect"]
    else:
        params["redirect"] = config.redirect
    # Render payment page with the request arguments (?amount= etc.)
    headers = {"Content-Type": "text/html"}
    return make_response(render_template("index.html", params=params), 200, headers)


# Now we build the API docs
# (if you do this before the above @app.routes then / gets overwritten.)
api = Api(
    app,
    version="0.1",
    title="qrlPay API",
    default="qrlPay /api/",
    description="API for creating QRL invoices and processing payments.",
    doc="/docs/",
    order=True,
)

# Model templates for API responses
invoice_model = api.model(
    "invoice",
    {
        "uuid": fields.String(),
        "dollar_value": fields.Float(),
        "qrl_value": fields.Float(),
        "method": fields.String(),
        "address": fields.String(),
        "time": fields.Float(),
        "webhook": fields.String(),
        "payment_id": fields.String(),
        "time_left": fields.Float(),
    },
)
status_model = api.model(
    "status",
    {
        "payment_complete": fields.Integer(),
        "confirmed_paid": fields.Float(),
        "unconfirmed_paid": fields.Float(),
        "expired": fields.Integer(),
    },
)


@api.doc(
    params={
        "amount": "An amount in USD.",
        "method": "(Optional) Specify a payment method: `qrld` for onchain.",
        "w_url": "(Optional) Specify a webhook url to call after successful payment. Currently only supports WooCommerce plugin.",
    }
)
class create_payment(Resource):
    @api.response(200, "Success", invoice_model)
    @api.response(400, "Invalid payment method")
    def get(self):
        "Create Payment"
        """Initiate a new payment with an `amount` in USD."""
        dollar_amount = request.args.get("amount")
        currency = "USD"
        label = ""  # request.args.get('label')
        payment_method = request.args.get("method")
        if payment_method is None:
            payment_method = config.pay_method
        webhook = request.args.get("w_url")

        if webhook is None:
            print("No webhook supplied. Not treating as a gateway payment.")
            webhook = None
        else:
            print("Webhook for finalising payment: {}".format(webhook))

        # Create the payment using one of the connected nodes as a base
        # ready to recieve the invoice.
        node = get_node(payment_method)
        if node is None:
            print("Invalid payment method {}".format(payment_method))
            return {"message": "Invalid payment method."}, 400

        invoice = {
            "uuid": str(uuid.uuid4().hex),
            "dollar_value": dollar_amount,
            "qrl_value": round(coingecko.get_qrl_value(dollar_amount, currency), 8),
            "method": payment_method,
            "time": time.time(),
            "webhook": webhook,
            "payment_id": ""
        }

        invoice["address"] = node.get_address()
        node.create_qr(invoice["uuid"], invoice["address"], invoice["qrl_value"])

        # Save invoice to database
        database.write_to_database(invoice)

        invoice["time_left"] = config.payment_timeout - (time.time() - invoice["time"])
        print("Created invoice:")
        pprint(invoice)
        print()

        return {"invoice": invoice}, 200


@api.doc(params={"uuid": "A payment uuid. Received from /createpayment."})
class check_payment(Resource):
    @api.response(200, "Success", status_model)
    @api.response(201, "Unconfirmed", status_model)
    @api.response(202, "Payment Expired", status_model)
    def get(self):
        "Check Payment"
        """Check the status of a payment."""
        uuid = request.args.get("uuid")
        status = check_payment_status(uuid)

        response = {
            "payment_complete": 0,
            "confirmed_paid": 0,
            "unconfirmed_paid": 0,
            "expired": 0,
        }

        # If payment is expired
        if status["time_left"] <= 0:
            response.update({"expired": 1})
            code = 202
        else:
            # Update response with confirmed and unconfirmed amounts
            response.update(status)

        # Return whether paid or unpaid
        if response["payment_complete"] == 1:
            code = 200
        else:
            code = 201

        return {"status": response}, code


@api.doc(params={"uuid": "A payment uuid. Received from /createpayment."})
class complete_payment(Resource):
    @api.response(200, "Payment confirmed.")
    @api.response(400, "Payment expired.")
    @api.response(500, "Webhook failure.")
    def get(self):
        "Complete Payment"
        """Run post-payment processing such as any webhooks."""
        uuid = request.args.get("uuid")
        order_id = request.args.get("id")

        invoice = database.load_invoice_from_db(uuid)
        status = check_payment_status(uuid)

        if status["time_left"] < 0:
            return {"message": "Expired."}, 400

        if status["payment_complete"] != 1:
            return {"message": "You havent paid."}

        print(invoice)

        # Call webhook to confirm payment with merchant
        if (invoice["webhook"] != None) and (invoice["webhook"] != ""):
            print("Calling webhook {}".format(invoice["webhook"]))
            print("Secret key: " + app.config["SECRET_KEY"])
            response = woo_webhook.hook(app.config["SECRET_KEY"], invoice, order_id)

            if response.status_code != 200:
                err = "Failed to confirm order payment via webhook {}, please contact the store to ensure the order has been confirmed, error response is: {}".format(
                    response.status_code, response.text
                )
                print(err)
                return err, 500

            print("successfully confirmed payment via webhook.")
            return {"message": "Payment confirmed with store."}, 200

        return {"message": "Payment confirmed."}, 200

                
def check_payment_status(uuid):
    status = {
        "payment_complete": 0,
        "confirmed_paid": 0,
        "unconfirmed_paid": 0,
    }
    invoice = database.load_invoice_from_db(uuid)
    if invoice is None:
        status.update({"time_left": 0, "not_found": 1})
    else:
        status["time_left"] = config.payment_timeout - (time.time() - invoice["time"])

    # If payment has not expired, then we're going to check for any transactions
    if status["time_left"] > 0:
        node = get_node(invoice["method"])
        conf_paid, unconf_paid, tx_ids = node.check_payment(invoice["address"])

        if invoice["qrl_value"] < config.zero_conf_limit:
            conf_paid += unconf_paid
            unconf_paid = 0

        # Debugging and demo mode which auto confirms payments after 5 seconds
        dbg_free_mode_cond = config.free_mode and (time.time() - invoice["time"] > 5)
        
        #Save tx_ids
        invoice["payment_id"] = tx_ids
      
            
        # If payment is paid
        if (conf_paid >= invoice["qrl_value"]) or dbg_free_mode_cond:
            # Save invoice to database
            database.update_database(invoice)
            
            status.update(
                {
                    "payment_complete": 1,
                    "confirmed_paid": conf_paid,
                    "unconfirmed_paid": unconf_paid,
                }
            )
            
            
        else:
            status.update(
                {
                    "payment_complete": 0,
                    "confirmed_paid": conf_paid,
                    "unconfirmed_paid": unconf_paid,
                }
            )

    print("invoice {} status: {}".format(uuid, status))
    return status


def get_node(payment_method):
    if payment_method == "qrld":
        node = qrl_node
    else:
        node = None
    return node


# Add API endpoints
api.add_resource(create_payment, "/api/createpayment")
api.add_resource(check_payment, "/api/checkpayment")
api.add_resource(complete_payment, "/api/completepayment")


parser = argparse.ArgumentParser("qrlPay - Self Hosted QRL Payment Gateway")


args, unknown = parser.parse_known_args()


log_file = "qrlPay.log"

# Test connections on startup:
print("connecting to node...")
with app.app_context():
    qrl_node = qrld.qrlnode()
    print("[[connection to QRL node successful]]")
    print("")
    print("")
