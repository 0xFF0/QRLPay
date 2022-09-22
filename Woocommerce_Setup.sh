#!/bin/bash
IMPORT_PRODUCTS=false
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

export $(cat env)

# Import product parameter
if [[ $1 == --import-products ]]; then
    IMPORT_PRODUCTS=true
fi

# Install packages
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install apache2 mysql-server php libapache2-mod-php php-mysql php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip -y

#Add port 80 and 443 to firewall
sudo ufw allow in "Apache Full"


# Mysql secure installation
echo "[+] MySQL configuration"
# Make sure that NOBODY can access the server without a password
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_PASS';"
# Kill the anonymous users
sudo mysql -e "DROP USER ''@'localhost'"
# Because our hostname varies we'll use some Bash magic here.
sudo mysql -e "DROP USER ''@'$(hostname)'"
# Delete anonymous user
sudo mysql -e "DELETE FROM mysql.user WHERE User=''"
# Ensure the root user can not log in remotely
sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
# Kill off the demo database
sudo mysql -e "DROP DATABASE test"
sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%'"
# Make our changes take effect
sudo mysql -e "FLUSH PRIVILEGES"

#Creating a Virtual Host
if [ ! -d /var/www/$DOMAIN_NAME ]; then
  echo "[+] Creating a Virtual Host"
  sudo mkdir /var/www/$DOMAIN_NAME
  sudo chown -R www-data:www-data /var/www
fi

echo "[+] Creating $DOMAIN_NAME.conf"
sudo tee /etc/apache2/sites-available/$DOMAIN_NAME.conf &>/dev/null <<EOF
<VirtualHost *:80>
    #ServerName $DOMAIN_NAME
    #ServerAlias www.$DOMAIN_NAME 
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/$DOMAIN_NAME
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
    <Directory /var/www/$DOMAIN_NAME/>
	AllowOverride All
    </Directory>
</VirtualHost>
EOF



#Disable default Apache website
sudo a2dissite 000-default



##################
#TODO 
###############
# https://www.digitalocean.com/community/tutorials/how-to-secure-apache-with-let-s-encrypt-on-ubuntu-20-04


#Create wordpress db
sudo mysql -e "CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci"
sudo mysql -e "CREATE USER '$MYSQL_WORDPRESS_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_WORDPRESS_PASS'"
sudo mysql -e "GRANT ALL ON wordpress.* TO '$MYSQL_WORDPRESS_USER'@'%'"
sudo mysql -e "FLUSH PRIVILEGES"


sudo a2ensite $DOMAIN_NAME
#reload Apache
sudo systemctl reload apache2


# WordPress setup
if ! sudo -u www-data test -f "/var/www/$DOMAIN_NAME/wp-config.php"; then
  echo "[+] Downloading and setting up Wordpress"
  cd /tmp
  curl -O https://wordpress.org/latest.tar.gz
  tar xzf latest.tar.gz
  touch /tmp/wordpress/.htaccess
  cp /tmp/wordpress/wp-config-sample.php /tmp/wordpress/wp-config.php
  mkdir /tmp/wordpress/wp-content/upgrade
  sudo -u www-data cp -a /tmp/wordpress/. /var/www/$DOMAIN_NAME
  sudo -u www-data find /var/www/$DOMAIN_NAME/ -type d -exec chmod 750 {} \;
  sudo -u www-data find /var/www/$DOMAIN_NAME/ -type f -exec chmod 640 {} \;
fi

# Updating salts
echo "[+] Updating wordpress salts"
curl https://api.wordpress.org/secret-key/1.1/salt/ -sSo salts
sudo csplit /var/www/$DOMAIN_NAME/wp-config.php '/AUTH_KEY/' '/NONCE_SALT/+1'
cat xx00 salts xx02 | sudo -u www-data tee /var/www/$DOMAIN_NAME/wp-config.php  > /dev/null
sudo rm salts xx00 xx01 xx02

# DB settings
sudo -u www-data sed -i "s/define( 'DB_NAME', 'database_name_here' );/define( 'DB_NAME', 'wordpress' );/g" /var/www/$DOMAIN_NAME/wp-config.php
sudo -u www-data sed -i "s/define( 'DB_USER', 'username_here' );/define( 'DB_USER', '$MYSQL_WORDPRESS_USER' );/g" /var/www/$DOMAIN_NAME/wp-config.php
sudo -u www-data sed -i "s/define( 'DB_PASSWORD', 'password_here' );/define( 'DB_PASSWORD', '$MYSQL_WORDPRESS_PASS' );/g" /var/www/$DOMAIN_NAME/wp-config.php
sudo -u www-data grep -qxF "define('FS_METHOD', 'direct');" /var/www/$DOMAIN_NAME/wp-config.php || echo "define('FS_METHOD', 'direct');" | sudo -u www-data tee -a /var/www/$DOMAIN_NAME/wp-config.php > /dev/null



# Installing wp-cli
if [ ! -f /usr/local/bin/wp ]; then
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  sudo mv wp-cli.phar /usr/local/bin/wp
fi

# Completing the installation
sudo -u www-data wp core install --url=$DOMAIN_NAME --title=$WORDPRESS_BLOG_TITLE --admin_user=$WORDPRESS_USER --admin_password=$WORDPRESS_PASS --admin_email=$WORDPRESS_ADMIN_EMAIL --path=/var/www/$DOMAIN_NAME


# Install woocommerce
sudo -u www-data mkdir /var/www/.wp-cli
sudo -u www-data wp plugin install woocommerce --path=/var/www/$DOMAIN_NAME --activate

sudo -u www-data wp option set woocommerce_store_address "123 Main Street" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_store_address_2 "" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_store_city "Los Angeles" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_default_country "US:CA" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_store_postcode "12345" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_currency "USD" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_product_type "downloads" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set woocommerce_allow_tracking "no" --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_stripe_settings '{"enabled":"no","create_account":false,"email":false}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_ppec_paypal_settings '{"reroute_requests":false,"email":false}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_cheque_settings '{"enabled":"no"}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_bacs_settings '{"enabled":"no"}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_cod_settings '{"enabled":"no"}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp theme install fastest-store --activate --path=/var/www/$DOMAIN_NAME
sudo wget -O /var/www/$DOMAIN_NAME/wp-content/themes/fastest-store/image/custom-header.jpg https://raw.githubusercontent.com/theQRL/assets/master/Tree/transparent-bg.png
sudo -u www-data wp media import https://raw.githubusercontent.com/theQRL/assets/master/logo/yellow.png --path=/var/www/$DOMAIN_NAME 
sudo wget -O /var/www/$DOMAIN_NAME/wp-content/themes/fastest-store/image/qrl-logo.png https://raw.githubusercontent.com/theQRL/assets/master/logo/yellow.png

if $BOOTSTRAP ; then
  #Products
  sudo -u www-data wp wc product create --name=Product0 --description=Description --regular_price=0.1 --user=$WORDPRESS_USER --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/logo/yellow.png"}]' 
  sudo -u www-data wp wc product create --name=Product1 --description=Description --regular_price=1 --user=$WORDPRESS_USER --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/logo/black.png"}]' 
  sudo -u www-data wp wc product create --name=Product2 --description=Description --regular_price=2 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/logo/yellow.png"}]' 
  sudo -u www-data wp wc product create --name=Product3 --description=Description --regular_price=3 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Tree/transparent-bg.png"}]'
  sudo -u www-data wp wc product create --name=Product4 --description=Description --regular_price=4 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/blue.png"}]'
  sudo -u www-data wp wc product create --name=Product5 --description=Description --regular_price=5 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/blue-10.png"}]'  
  sudo -u www-data wp wc product create --name=Product6 --description=Description --regular_price=6 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/dark.png"}]'  
  sudo -u www-data wp wc product create --name=Product7 --description=Description --regular_price=7 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/yellow.png"}]' 
  sudo -u www-data wp wc product create --name=Product8 --description=Description --regular_price=8 --user=$WORDPRESS_USER --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/logo/black.png"}]'  
  sudo -u www-data wp wc product create --name=Product9 --description=Description --regular_price=9 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Tree/dark-bg.png"}]'
  sudo -u www-data wp wc product create --name=Product10 --description=Description --regular_price=10 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Tree/dark-bg.png"}]'
  sudo -u www-data wp wc product create --name=Product11 --description=Description --regular_price=15 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Icon/yellow/yellow_200x200.png"}]'  
  sudo -u www-data wp wc product create --name=Product12 --description=Description --regular_price=30 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Icon/dark/dark_200x200.png"}]' 
  sudo -u www-data wp wc product create --name=Product13 --description=Description --regular_price=50 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/yellow-30.png"}]' 
  sudo -u www-data wp wc product create --name=Product14 --description=Description --regular_price=100 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Dots/dark-30.png"}]' 
  sudo -u www-data wp wc product create --name=Product15 --description=Description --regular_price=200 --user=$WORDPRESS_USER  --path=/var/www/$DOMAIN_NAME --images='[{"src":"https://raw.githubusercontent.com/theQRL/assets/master/Tree/dark-bg.png"}]' 
fi

# QRL payment gateway setup
cd $SCRIPTPATH
sudo -u www-data cp app/gateways/woo_qrlpay.php /var/www/$DOMAIN_NAME/wp-content/plugins/
sudo -u www-data wp plugin activate woo_qrlpay --path=/var/www/$DOMAIN_NAME
sudo -u www-data wp option set --format=json woocommerce_qrlpay_settings '{"enabled":"yes"}' --path=/var/www/$DOMAIN_NAME
sudo -u www-data sed -i "s/qrlpay_server_url_value/${QRLPAY_URL//\//\\/}/g" /var/www/$DOMAIN_NAME/wp-content/plugins/woo_qrlpay.php
python3 -c "import os;print(os.urandom(64).hex());" > qrlPay_API_key
QRL_API_KEY=$(cat qrlPay_API_key)
sudo -u www-data sed -i "s/qrlpay_API_Key_value/$QRL_API_KEY/g" /var/www/$DOMAIN_NAME/wp-content/plugins/woo_qrlpay.php

# Remove some default pages 
SAMPLE_PAGE_ID=$(sudo -u www-data wp post list --post_type='page' --path=/var/www/$DOMAIN_NAME | grep "Sample Page" | awk '{ print $1 }')
if [ ! -z "$SAMPLE_PAGE_ID" ]; then
  sudo -u www-data wp post delete $SAMPLE_PAGE_ID --path=/var/www/$DOMAIN_NAME 
fi

# Update front page
SHOP_PAGE_ID=$(sudo -u www-data wp post list --post_type='page' --path=/var/www/$DOMAIN_NAME | grep "Shop" | awk '{ print $1 }')
if [ ! -z "$SHOP_PAGE_ID" ]; then
  sudo -u www-data wp option update page_on_front $SHOP_PAGE_ID --path=/var/www/$DOMAIN_NAME
  sudo -u www-data wp option update show_on_front page --path=/var/www/$DOMAIN_NAME
fi

# Delete hello world
sudo -u www-data wp post delete 1 --path=/var/www/$DOMAIN_NAME 

#Update Just another wordpress
sudo -u www-data wp option update blogdescription "QRLPay eCommerce demo #hackathon2022" --path=/var/www/$DOMAIN_NAME



