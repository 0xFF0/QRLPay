import sqlite3


def create_database(name="database.db"):
    with sqlite3.connect("database.db") as conn:
        print("Creating new database.db...")
        conn.execute(
            "CREATE TABLE payments (uuid TEXT, dollar_value DECIMAL, qrl_value DECIMAL, method TEXT, address TEXT, time DECIMAL, webhook TEXT, payment_id TEXT)"
        )
    return


def write_to_database(invoice, name="database.db"):
    with sqlite3.connect("database.db") as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO payments (uuid,dollar_value,qrl_value,method,address,time,webhook, payment_id) VALUES (?,?,?,?,?,?,?,?)",
            (
                invoice["uuid"],
                invoice["dollar_value"],
                invoice["qrl_value"],
                invoice["method"],
                invoice["address"],
                invoice["time"],
                invoice["webhook"],
                invoice["payment_id"],
            ),
        )
    return

def update_database(invoice, name="database.db"):
    with sqlite3.connect("database.db") as conn:
        cur = conn.cursor()
        sql_update="""UPDATE payments SET uuid = ?, dollar_value = ?, qrl_value = ?, method = ?, address = ?, time = ?, webhook = ?, payment_id = ? WHERE uuid = ?"""
        data=(
                invoice["uuid"],
                invoice["dollar_value"],
                invoice["qrl_value"],
                invoice["method"],
                invoice["address"],
                invoice["time"],
                invoice["webhook"],
                invoice["payment_id"],
                invoice["uuid"],
            )
        cur.execute(sql_update,data)
        conn.commit()
    return

def load_invoice_from_db(uuid):
    with sqlite3.connect("database.db") as conn:
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()
        rows = cur.execute(
            "select * from payments where uuid='{}'".format(uuid)
        ).fetchall()
    if len(rows) > 0:
        return [dict(ix) for ix in rows][0]
    else:
        return None
