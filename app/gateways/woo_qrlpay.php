<?php
/*
 * Plugin Name: qrlpay
 * Plugin URI: https://github.com/0xFF0/qrlpay
 * Description: Take QRL payments on your store.
 * Author: 0xFF (fork from Nick Farrow & xmrSale Dev)
 * Version: 1.0.1
 *
*/

/* Based.
* Based on https://rudrastyh.com/woocommerce/payment-gateway-plugin.html */

/*
 * This action hook registers our PHP class as a WooCommerce payment gateway
 */

// Debugging helper
// Writes to wp-content/debug.log
 if (!function_exists('write_log')) {
     function write_log($log) {
         if (true) {
             if (is_array($log) || is_object($log)) {
                 error_log(print_r($log, true));
             } else {
                 error_log($log);
             }
         }
     }
 }

// qrlpay class
add_filter( 'woocommerce_payment_gateways', 'qrlpay_add_gateway_class' );
function qrlpay_add_gateway_class( $gateways ) {
	$gateways[] = 'WC_qrlpay_Gateway';
	return $gateways;
}

// Extend existing payment gateway
add_action( 'plugins_loaded', 'qrlpay_init_gateway_class' );
function qrlpay_init_gateway_class() {
	class WC_qrlpay_Gateway extends WC_Payment_Gateway {

        public static $secret = 0;
 		/**
 		 * Class constructor
 		 */
 		public function __construct() {

           	$this->id = 'qrlpay'; // payment gateway plugin ID
           	$this->icon = 'http://127.0.0.1/wp-content/themes/fastest-store/image/qrl-logo.png'; // URL of the icon that will be displayed on checkout page near your gateway name
           	$this->has_fields = true; // in case you need a custom credit card form
           	$this->method_title = 'qrlpay Gateway';
           	$this->method_description = 'qrlpay payment gateway'; // will be displayed on the options page

           	$this->supports = array(
           		'products'
           	);

           	// Method with all the options fields
           	$this->init_form_fields();

           	// Load the settings.
           	$this->init_settings();
           	$this->title = $this->get_option( 'title' );
           	$this->description = $this->get_option( 'description' );
           	$this->enabled = $this->get_option( 'enabled' );
            $this->qrlpay_server_url = $this->get_option( 'qrlpay_server_url' );
            // $this->redirect_url = $this->get_option( 'redirect_url' );
           	// $this->testmode = 'yes' === $this->get_option( 'testmode' );
           	$this->qrlpay_API_Key = $this->get_option( 'qrlpay_API_Key' );

            $this->callback_URL = str_replace( 'https:', 'http:', add_query_arg( 'wc-api', 'wc_qrlpay_gateway', home_url( '/' ) ) );
            // $this->callback_URL = home_url( '/' ) . 'wc-api/' . 'WC_qrlpay_Gateway/';

           	// This action hook saves the settings
           	add_action( 'woocommerce_update_options_payment_gateways_' . $this->id, array( $this, 'process_admin_options' ) );

           	// You can also register a webhook here
           	add_action( 'woocommerce_api_wc_qrlpay_gateway', array( $this, 'webhook' ) );
 		}
 		
 		public function get_transaction_url( $order ) {

			$this->view_transaction_url = 'https://explorer.theqrl.org/tx/%s';
       		return parent::get_transaction_url( $order );
		}

		/**
 		 * Plugin options
 		 */
 		public function init_form_fields(){

            	$this->form_fields = array(
            		'enabled' => array(
            			'title'       => 'Enable/Disable',
            			'label'       => 'Enable qrlpay Gateway',
            			'type'        => 'checkbox',
            			'description' => '',
            			'default'     => 'no'
            		),
            		'title' => array(
            			'title'       => 'Title',
            			'type'        => 'text',
            			'description' => 'This controls the title which the user sees during checkout.',
            			'default'     => 'QRL',
            			'desc_tip'    => true,
            		),
            		'description' => array(
            			'title'       => 'Description',
            			'type'        => 'textarea',
            			'description' => 'This controls the description which the user sees during checkout.',
            			'default'     => 'Pay with QRL via qrlpay',
            		),
                    'qrlpay_server_url' => array(
                        'title'       => 'qrlpay URL',
                        'type'        => 'text',
                        'description' => 'Points towards your instance of qrlpay, should be IP or https://SERVER.com',
                        'default'     => 'qrlpay_server_url_value',
                    ),
            		'qrlpay_API_Key' => array(
            			'title'       => 'qrlpay_API_Key',
            			'type'        => 'text',
            			'default'     => 'qrlpay_API_Key_value',
            		)
            	);
	 	}

		/*
		 * Processing the payments
		 */
         public function process_payment( $order_id ) {

         	global $woocommerce;

         	// we need it to get any order details
         	$order = wc_get_order( $order_id );

            // We need to store a signature of the data, and check it later during the webhook to confirm it is the same!
         	/*
          	 * Array with parameters for API interaction
         	 */
         	$args = array(
                'amount' => $order->get_total(),
                'w_url' => $this->callback_URL,
                'id' => $order_id,
                'redirect' => $this->get_return_url( $order ));

            write_log($args);

            $key = hex2bin($this->qrlpay_API_Key);

             $payment_url = add_query_arg(
                $args,
                $this->qrlpay_server_url . '/pay'
            );

            // Redirect to qrlpay
            return [
                'result'   => 'success',
                'redirect' => $payment_url
            ];
         }

		 /*
		 * Webhook to confirm payment
		 */
         public function webhook() {
            $order = wc_get_order( $_GET['id'] );
			$headers = getallheaders();

			$now = time(); // current unix timestamp
			$json = json_encode($_GET, JSON_FORCE_OBJECT);
            $key = hex2bin($this->qrlpay_API_Key);

            // Order secret must match to ensure inital payment url
            // had not been tampered when leaving the gateway.
            // This secret is generated within the python backend (gateways/woo_webhook.py)
            // For the payment to succeed, this will be provided in the success request header
            // once the payment has been confirmed by the python backend.
            // By confirming it matches the order details (amount * id) we know that
            // the order has not been tampered with after leaving the php payment gateway.
            $order_secret_seed = (int)($order->get_total() * 100.0);
            $order_secret_seed_str = (string)$order_secret_seed;
            $secret = hash_hmac('sha256', $order_secret_seed, $key);

            if ($headers['X-Secret'] != $secret) {
                header( 'HTTP/1.1 403 Forbidden' );
				return 1;
            }

            // Main Signature.
            // Get supplied signature
            $signature = $headers['X-Signature'];

            // Calculate expected signature
            $valid_signature = hash_hmac('sha256', $_GET['time'] .'.'.$json, $key);

            // Get transaction id
            $tx_id = $headers['tx_id'];
            
            // Compare signature and timestamps
			if (hash_equals($signature, $valid_signature) and (abs($now - $_GET['time']) < 5)) {
	            header( 'HTTP/1.1 200 OK' );
                // Complete order
                	$order->set_transaction_id($tx_id);
	         	$order->payment_complete($tx_id);
	         	$order->reduce_order_stock();
	         	$order->add_order_note("Payment received: https://explorer.theqrl.org/tx/$tx_id");	         	
	         	update_option('webhook_debug', $_GET);

			} else {
				header( 'HTTP/1.1 403 Forbidden' );
				return 1;
			}
			exit();

         }
 	}
}
