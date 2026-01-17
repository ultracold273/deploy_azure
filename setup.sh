#!/bin/bash

CERT_PATH=/etc/letsencrypt/live
CERT_CHALLENGE_PATH=/var/www/acme-challenge
DOMAIN=$1
DOMAINV6=$2
IPADDR=$3
SS_PORT=$4
NTFY_TOPIC=${5:-}
PASSWORD1=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)
PASSWORD2=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

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
    execute useradd -r -M -G certusers hysteria
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
        proxy_pass https://google.com;
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
    run_as_user acme "acme.sh --issue -d $DOMAINV6 -w $CERT_CHALLENGE_PATH"
    run_as_user acme "acme.sh --install-cert \
        -d $DOMAINV6 \
        --key-file $CERT_PATH/privatev6.key \
        --fullchain-file $CERT_PATH/certificatev6.crt"
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
    curl -fsSL https://raw.githubusercontent.com/ultracold273/deploy_azure/main/go-trojan.sh | bash -s -- $CERT_PATH $PASSWORD1

    execute chown -R trojan:trojan $TROJAN_CONFIG
    
    echo "Enable Trojan to bind ports with number lower than 1024"
    execute setcap CAP_NET_BIND_SERVICE=+eip $TROJAN_BIN

    execute systemctl enable trojan
    execute systemctl restart trojan

    echo "0 0 1 * * killall -s SIGUSR1 trojan" | crontab -u trojan -
}

setup_hysteria() {
    HYSTERIA_BIN=/usr/local/bin/hysteria
    HYSTERIA_CONFIG=/usr/local/etc/hysteria
    HYSTERIA_CONFIG_FILE=$HYSTERIA_CONFIG/config.yaml
    echo "Install Hysteria ..."
    curl -fsSL https://raw.githubusercontent.com/ultracold273/deploy_azure/main/go-hysteria2.sh | bash -s -- $CERT_PATH $PASSWORD1

    execute chown -R hysteria:hysteria $HYSTERIA_CONFIG
    
    echo "Enable Hysteria to bind ports with number lower than 1024"
    execute setcap CAP_NET_BIND_SERVICE=+eip $HYSTERIA_BIN

    execute systemctl enable hysteria
    execute systemctl restart hysteria
}

setup_shadowsocks() {
    SS_BIN=/usr/local/bin/ssservice
    SS_CONFIG=/usr/local/etc/shadowsocks
    SS_CONFIG_FILE=$SS_CONFIG/config.json

    echo Install Shadowsocks ..
    curl -fsSL https://raw.githubusercontent.com/ultracold273/deploy_azure/main/go-shadowsocks.sh | bash -s -- $SS_PORT $PASSWORD2

    execute systemctl enable shadowsocks
    execute systemctl restart shadowsocks
}

ip_stack_setup() {
    # Enable BBR congestion control
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    # Bind IPv6 socket to IPv6 only, required by Hysteria
    echo "net.ipv6.bindv6only=1" >> /etc/sysctl.conf
    sysctl -p
}

setup_monitoring() {
    MONITOR_SCRIPT=/usr/local/bin/monitor.sh
    MONITOR_CONFIG_DIR=/usr/local/etc/monitor
    MONITOR_CONFIG=$MONITOR_CONFIG_DIR/config.env
    MONITOR_URL="https://raw.githubusercontent.com/ultracold273/deploy_azure/main/monitor.sh"
    
    echo "Installing monitoring script..."
    curl -fsSL $MONITOR_URL -o $MONITOR_SCRIPT
    chmod +x $MONITOR_SCRIPT
    
    # Create state directory
    mkdir -p /var/run/service-monitor
    
    # Create config directory and environment file
    mkdir -p $MONITOR_CONFIG_DIR
    cat <<EOF > $MONITOR_CONFIG
NTFY_TOPIC=$NTFY_TOPIC
VM_NAME=$DOMAIN
EOF
    chmod 600 $MONITOR_CONFIG
    
    # Add cron job to run 4 times daily (every 6 hours: midnight, 6am, noon, 6pm UTC)
    echo "0 */6 * * * root $MONITOR_SCRIPT" > /etc/cron.d/service-monitor
    chmod 644 /etc/cron.d/service-monitor
    
    # Add Hysteria certificate reload cron (was missing)
    echo "0 0 1 * * root systemctl restart hysteria" > /etc/cron.d/hysteria-cert-reload
    chmod 644 /etc/cron.d/hysteria-cert-reload
    
    echo "Monitoring setup complete. Alerts will be sent to ntfy.sh/$NTFY_TOPIC"
}

if [ $# -lt 4 ]; then
    echo "Error: You need at least four arguments (DOMAIN, DOMAINV6, IPADDR, SS_PORT)"
    exit 1
fi

install_deps
create_users
setup_nginx
setup_acme
setup_trojan
setup_hysteria
setup_shadowsocks
ip_stack_setup
setup_monitoring

echo Done!
echo \[Summary\]: Setup your Trojan \(Domain: $DOMAIN\)/Hysteria2 \(Domain: $DOMAINV6\) client with $PASSWORD1, Port: 443 and SS \(Domain: $DOMAIN\) client with $PASSWORD2, Port: $SS_PORT
