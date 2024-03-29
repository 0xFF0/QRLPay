#!/bin/bash
NET_NAME=Mainnet    # Mainnet/Testnet
PRODUCTION=true
BOOTSTRAP=false
WOOCOMMERCE_SETUP=false

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
QRL_DATA_DIR=./qrlData/$NET_NAME
BOOTSTRAP_DEST=$QRL_DATA_DIR/data
BOOTSTRAP_FILE_NAME=QRL_"$NET_NAME"_State.tar.gz
CHECKSUM_FILE="$NET_NAME"_State_Checksums.txt
BOOTSTRAP_URL=https://cdn.qrl.co.in/${NET_NAME,,}/$BOOTSTRAP_FILE_NAME
BOOTSTRAP_URL_CHECKSUM=https://cdn.qrl.co.in/${NET_NAME,,}/$CHECKSUM_FILE
BASE=data/gunicorn
NB_WORKERS=$((($(grep -c ^processor /proc/cpuinfo) * 2) + 1))
WEB_PORT=5000

if $PRODUCTION ; then
  WEB_PORT=4000
fi

export $(cat env)

# Create data folder
if [ ! -d data ]; then
  mkdir -p data
fi


# Create qrlData folder
if [ ! -d $BOOTSTRAP_DEST ]; then
  mkdir -p $BOOTSTRAP_DEST
fi

# Bootstrap parameter
if [[ $1 == --bootstrap ]]; then
    BOOTSTRAP=true
fi
if [[ $2 == --bootstrap ]]; then
    BOOTSTRAP=true
fi

# Woocommerce parameter
if [[ $1 == --woocommerce ]]; then
    WOOCOMMERCE_SETUP=true
fi
if [[ $2 == --woocommerce ]]; then
    WOOCOMMERCE_SETUP=true
fi



# Install packages
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install docker.io docker-compose python3.8-venv python3-pip python3-wheel curl -y


# Bootstrap
if $BOOTSTRAP ; then
  DOWNLOAD_BOOTSTRAP=true
  if [ -f "$BOOTSTRAP_FILE_NAME" ]; then
    echo "$BOOTSTRAP_FILE_NAME already exists."
    read -p "Do you wish to download the bootstrap again (y/n)?" yn
    case $yn in
        [Yy]* ) rm $BOOTSTRAP_FILE_NAME; rm $CHECKSUM_FILE;;
        [Nn]* ) DOWNLOAD_BOOTSTRAP=false;;
        * ) echo "Please answer yes or no.";;
    esac
  fi

  if $DOWNLOAD_BOOTSTRAP ; then
    wget $BOOTSTRAP_URL_CHECKSUM
    wget $BOOTSTRAP_URL
	echo "SHA3-512 checksum verification started..."
    SHA3_CHECKSUM=`sed -n '/SHA3-512/{n;p}' $CHECKSUM_FILE`
    SHA3=($(openssl dgst -sha3-512 $BOOTSTRAP_FILE_NAME))
    if [ "$SHA3_CHECKSUM" = "${SHA3[1]}" ]; then
      echo "Verification ok: $SHA3_CHECKSUM ."
	  echo "Extracting bootstrap data..."
      tar -xzf $BOOTSTRAP_FILE_NAME -C $BOOTSTRAP_DEST  
    else
      echo "Bootstrap verification failed. Expected $SHA3_CHECKSUM got ${SHA3[1]}."
      exit 1
    fi
  fi
fi

# Set network type for the docker container
if [[ $NET_NAME == Mainnet ]]; then
  sed -i 's/start_qrl --network-type testnet \&/start_qrl \&/g' dockerfiles/RunWallet.sh
  sed -i 's/RUN pip3 install -U "qrl==3.0.1"/RUN pip3 install -U qrl/g' dockerfiles/QRL_wallet.docker
else
  #Testnet temporary patch, waiting for 4.0 update
  sed -i 's/RUN pip3 install -U qrl/RUN pip3 install -U "qrl==3.0.1"/g' dockerfiles/QRL_wallet.docker
fi

# TODO: Looks like a bug for testnet, no config.yml and genesis.yml created with root account on docker
if [[ $NET_NAME == Testnet ]]; then
  cat << EOF > $QRL_DATA_DIR/config.yml
peer_list: [ "18.130.83.207", "209.250.246.234", "136.244.104.146", "95.179.154.132" ]
genesis_prev_headerhash: 'Testnet 2022'
genesis_timestamp: 1641963062
genesis_difficulty: 5000
EOF
  cat << EOF > $QRL_DATA_DIR/genesis.yml
genesisBalance:
- address: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  balance: '105000000000000000'
header:
  hashHeader: LGyQSHq8RYrEHmG7VVtmc9YIqHNxFIH9IMrUTo34lJ0=
  hashHeaderPrev: VGVzdG5ldCAyMDIy
  merkleRoot: wquld1GTaqfKWRhAdWpOeREWVdCmlTYIAUrY9eWGwTQ=
  rewardBlock: '65000000000000000'
  timestampSeconds: '1641963062'
transactions:
- coinbase:
    addrTo: AQYA3oDYKOMv8cfAHpT2zewSkuiz/0gYQy5+atQfOsdD57loCQog
    amount: '65000000000000000'
  masterAddr: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  nonce: '1'
  transactionHash: wquld1GTaqfKWRhAdWpOeREWVdCmlTYIAUrY9eWGwTQ=
EOF

  sed -i 's/start_qrl \&/start_qrl --network-type testnet \&/g' dockerfiles/RunWallet.sh

fi

# QRL node configuration
cat << EOF >> $QRL_DATA_DIR/config.yml
public_api_host: '0.0.0.0'
mining_api_enabled: True
mining_api_host: '0.0.0.0'
EOF


# Python setup
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
.venv/bin/pip install -r requirements.txt


# Start docker-compose
sudo docker-compose -f docker-compose-qrl-pay.yaml up -d --build

# Woocommerce
if $WOOCOMMERCE_SETUP ; then
  ./Woocommerce_Setup.sh --import-products
fi 


#Flask init
source .venv/bin/activate
export FLASK_APP=app/app.py
export FLASK_SECRETS=config.py
export FLASK_DEBUG=0
export FLASK_ENV=production
#flask init

# Web app
if $PRODUCTION ; then

  mkdir -p $BASE

  kill $(cat $BASE/gunicorn.pid) 2>&1

  sleep 2

  gunicorn \
    --bind 0.0.0.0:$WEB_PORT "app.app:app" \
    --daemon \
    --log-file $BASE/gunicorn.log \
    --pid $BASE/gunicorn.pid \
    --access-logfile $BASE/access.log \
    --workers $NB_WORKERS \
    --timeout 120 \
    --capture-output \
    --reload

  sleep 2

  echo "Starting gunicorn with pid $(cat $BASE/gunicorn.pid)"

else

  export FLASK_DEBUG=1
  export FLASK_ENV=development
  flask run
fi



