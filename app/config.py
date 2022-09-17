import os
from os import getenv

# QRL node connection settings
host = "127.0.0.1"

# File in which API key will be stored
api_key_path = "qrlPay_API_key"

# Amount $X you want to instantly accept 0-conf payments under. (or None)
zero_conf_limit = 0

# Check for payment every xx seconds
pollrate = 15

# Payment expires after xx seconds
payment_timeout = 60*60

# Required confirmations for a payment
required_confirmations = 5

# Global connection attempts
connection_attempts = 5

# Generic redirect url after payment
redirect = "https://github.com/0xFF0/qrlpay"

# Payment method
pay_method = "qrld"

# DO NOT CHANGE THIS TO TRUE UNLESS YOU WANT ALL PAYMENTS TO AUTOMATICALLY
# BE CONSIDERED AS PAID.
free_mode = False


QRL_WALLET_API_HOST=getenv('QRL_WALLET_API_HOST')
QRL_WALLET_API_PORT=getenv('QRL_WALLET_API_PORT')
