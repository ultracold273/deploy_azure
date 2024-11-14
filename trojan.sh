#!/bin/bash

CERT_PATH=/etc/letsencrypt/live
CERT_CHALLENGE_PATH=/var/www/acme-challenge
DOMAIN=$1
IPADDR=$2
PASSWORD1=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)
PASSWORD2=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)

execute() {
    echo "Execute: $*"
    "$@"
}

install_deps() {
    echo "Install dependencies ..."
    apt update -y
    apt install -y socat cron curl libcap2-bin xz-utils nginx
}

create_users() {
    execute groupadd certusers
    execute useradd -r -M -G certusers trojan
    execute useradd -r -m -G certusers acme
}

setup_nginx() {
    NGINX_ENABLE_SITE=/etc/nginx/sites-enabled
    NGINX_AVAILABLE_SITE=/etc/nginx/sites-available    
    echo "Setting up nginx.."
    execute rm $NGINX_ENABLE_SITE/default
    execute generate_nginx_template $NGINX_AVAILABLE_SITE/$DOMAIN $DOMAIN $IPADDR
    execute ln -s $NGINX_AVAILABLE_SITE/$DOMAIN $NGINX_ENABLE_SITE

    execute systemctl enable nginx
    execute systemctl restart nginx

    execute usermod -G certusers www-data
}

generate_nginx_template() {
    filename=$1
    domain=$2
    ipaddr=$3
    cat <<EOF > $1
server {
    listen 127.0.0.1:80 default_server;
    server_name $domain;
    location / {
        proxy_pass https://ultracold273.github.io;
    }
}

server {
    listen 127.0.0.1:80;
    server_name $ipaddr;
    return 301 https://$domain\$request_uri;
}

server {
    listen 0.0.0.0:80;
    listen [::]:80;
    server_name _;
    location / {
        return 301 https://\$host\$request_uri;
    }
    location /.well-known/acme-challenge {
        root /var/www/acme-challenge;
    }
}
EOF
}

setup_acme() {
    echo "Create Cert Path..."
    execute mkdir -p $CERT_PATH
    execute chown -R acme:certusers $CERT_PATH
    execute chmod -R 750 $CERT_PATH

    echo "Create Cert Challenge Path..."
    execute mkdir -p $CERT_CHALLENGE_PATH
    execute chown -R acme:certusers $CERT_CHALLENGE_PATH

    echo "Issue certificate"
    run_as_user acme "curl https://get.acme.sh | sh"
    run_as_user acme "acme.sh --set-default-ca --server letsencrypt"
    run_as_user acme "acme.sh --issue -d $DOMAIN -w $CERT_CHALLENGE_PATH"
    run_as_user acme "acme.sh --install-cert \
        -d $DOMAIN \
        --key-file $CERT_PATH/private.key \
        --fullchain-file $CERT_PATH/certificate.crt"
    run_as_user acme "acme.sh --upgrade --auto-upgrade"

    echo "Grant keys to certusers groups"
    execute chown -R acme:certusers $CERT_PATH
    execute chmod -R 750 $CERT_PATH
}

run_as_user() {
    echo "su - $1 -c \"$2\""
    su - $1 -c "$2"
}

setup_trojan() {
    TROJAN_BIN=/usr/local/bin/trojan
    TROJAN_CONFIG=/usr/local/etc/trojan
    TROJAN_CONFIG_FILE=$TROJAN_CONFIG/config.json
    echo "Install Trojan ..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/trojan-gfw/trojan-quickstart/master/trojan-quickstart.sh)"
    execute chown -R trojan:trojan $TROJAN_CONFIG
    execute rm $TROJAN_CONFIG_FILE
    execute generate_trojan_config $TROJAN_CONFIG_FILE
    execute sed -i '/\[Service\]/a User=trojan' /etc/systemd/system/trojan.service

    execute systemctl daemon-reload

    echo "Enable Trojan to bind ports with number lower than 1024"
    execute setcap CAP_NET_BIND_SERVICE=+eip $TROJAN_BIN

    execute systemctl enable trojan
    execute systemctl restart trojan

    echo "0 0 1 * * killall -s SIGUSR1 trojan" | crontab -u trojan -
}

enable_congestion_control() {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
}

generate_trojan_config() {
    cat<<EOF > $1
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$PASSWORD1",
        "$PASSWORD2"
    ],
    "log_level": 1,
    "ssl": {
        "cert": "$CERT_PATH/certificate.crt",
        "key": "$CERT_PATH/private.key",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384",
        "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
        "prefer_server_cipher": true,
        "alpn": [
            "http/1.1"
        ],
        "alpn_port_override": {
            "h2": 81
        },
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": false,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": false,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": false,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": "",
        "key": "",
        "cert": "",
        "ca": ""
    }
}
EOF
}

if [ $# -lt 2 ]; then
    echo "Error: You need at least two arguments"
    exit 1
fi

install_deps
create_users
setup_nginx
setup_acme
setup_trojan
enable_congestion_control

echo "Done!"
echo "Now you can setup your client with passcode: $PASSWORD1 or $PASSWORD2"

