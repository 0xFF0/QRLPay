import click
from flask import Blueprint
from app.factory import db


bp = Blueprint('cli', 'cli', cli_group=None)




@bp.cli.command('process_payouts')
def process_payouts():
    import arrow
    from time import sleep
    from app.models import Operation, Payout
    from app.library.qrl import wallet, qrl
    from app.library.digitalocean import do
    from app.helpers import to_ausd
    from app.helpers import cancel_operation
    from app import config
    from decimal import Decimal

    click.echo(f'Processing payouts started.')
    operations = Operation.query.all()
    for op in operations:
        if op.droplet_id:
            click.echo(f'Processing cost of node for operation {op.codename} ({op.id})')
            prices = op.get_pricing(live=True)
            balances = Decimal(wallet.balances(op.address, atomic=True))
            latest_payout = Payout.query.filter(
                Payout.operation_id == op.id
            ).order_by(Payout.create_date.desc()).first()
            if latest_payout is None:
                #last = arrow.get(do.show_droplet(op.droplet_id)['created_at']).datetime
                last = arrow.utcnow().shift(hours=-config.PAYOUT_FREQUENCY)
                latest_payout = 'droplet boot time'
            else:
                last = arrow.get(latest_payout.create_date).datetime
                latest_payout = str(latest_payout.id)

            diff = arrow.utcnow() - last
            minutes = diff.total_seconds() / 60
            hours = minutes / 60
            qrl_to_send = hours * prices['in_qrl']
            aqrl_to_send = qrl.to_atomic(qrl_to_send)
            unlocked_qrl = qrl.from_atomic(balances)
            msg = [
                f' - QRL balance in wallet: {unlocked_qrl} ',
                f'\n - QRL market price: ${prices["qrl_price"]}',
                f'\n - Droplet Cost: ${prices["droplet_cost"]}/hour',
                f'\n - Mgmt Cost: ${prices["mgmt_cost"]}/hour',
                f'\n - Total Cost: ${prices["in_usd"]}/hour ({prices["in_qrl"]} QRL/hour)',
                f'\n - Last payout: {str(latest_payout)}',
                f'\n - {hours} hours ({minutes} minutes) since last payout.',
                f'\n - Planning to send {qrl_to_send} QRL to payout address',
                f'\n - Payout every {config.PAYOUT_FREQUENCY} hours at minimum',
            ]
            click.echo("".join(msg))

            if hours > config.PAYOUT_FREQUENCY:
                click.echo(' - Proceeding to payout.....')
                sleep(10)
                if balances > aqrl_to_send:
                    res = wallet.transfer(op.address, config.PAYOUT_ADDRESS, aqrl_to_send)
                    if 'tx' in res:
                        click.echo(f' - Sent QRL, Tx ID: {res["tx"]["transaction_hash"]}')
                        p = Payout(
                            operation_id=op.id,
                            total_cost_ausd=to_ausd(prices['in_usd']),
                            qrl_price_ausd=to_ausd(prices['qrl_price']),
                            qrl_sent_aqrl=aqrl_to_send,
                            qrl_tx_id=res["tx"]["transaction_hash"],
                            hours_since_last=round(hours)
                        )
                        db.session.add(p)
                        db.session.commit()
                        click.echo(f' - Save payout details as {p.id}')
                    elif 'error' in res:
                        click.echo(f' - There was a problem sending QRL: {res["error"]}')
                    else:
                        click.echo(' - Unable to send QRL')
                else:
                    click.echo(f' - Not enough unlocked balance ({qrl.from_atomic(balances)}) to send QRL')

                if balances < aqrl_to_send:
                    click.echo(' - There is not enough balance, this droplet should be destroyed')
                    sleep(5)
                    cancel_operation(op.codename)
            else:
                click.echo(' - Skipping payout, not enough time elapsed')




