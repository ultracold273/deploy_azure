#!/bin/bash
#
# Service and Certificate Monitoring Script
# Monitors: nginx, trojan, hysteria, shadowsocks-rust services and SSL certificates
# Features: layered health checks, auto-remediation with rate limiting, ntfy.sh alerts
#

# Source config file if it exists (for environment variables)
CONFIG_FILE="/usr/local/etc/monitor/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Configuration
CERT_PATH=/etc/letsencrypt/live
STATE_DIR=/var/run/service-monitor
LOG_FILE=/var/log/monitor.log
NTFY_TOPIC="${NTFY_TOPIC:-}"
VM_NAME="${VM_NAME:-$(hostname)}"

# Thresholds
CERT_WARN_DAYS=14
CERT_CRITICAL_DAYS=3
MAX_RESTARTS=3
RESTART_WINDOW=86400  # 24 hours in seconds

# Services to monitor
SERVICES=("nginx" "trojan" "hysteria" "shadowsocks")

# Certificate files to check
CERT_FILES=("certificate.crt" "certificatev6.crt")

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Send alert via ntfy.sh
send_alert() {
    local title="[$VM_NAME] $1"
    local message="$2"
    local priority="${3:-default}"  # default, low, high, urgent
    
    log "ALERT" "$title: $message"
    
    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -sf \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: server,monitor" \
            -d "$message" \
            "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1
        
        if [[ $? -eq 0 ]]; then
            log "INFO" "Alert sent to ntfy.sh/$NTFY_TOPIC"
        else
            log "ERROR" "Failed to send alert to ntfy.sh"
        fi
    else
        log "WARN" "NTFY_TOPIC not configured, alert logged only"
    fi
}

# Check if restart is allowed (rate limiting)
can_restart() {
    local service="$1"
    local state_file="$STATE_DIR/${service}_restarts"
    local now=$(date +%s)
    local cutoff=$((now - RESTART_WINDOW))
    
    # Create state file if not exists
    touch "$state_file"
    
    # Remove old entries and count recent restarts
    local temp_file=$(mktemp)
    local count=0
    
    while read -r timestamp; do
        if [[ "$timestamp" -ge "$cutoff" ]]; then
            echo "$timestamp" >> "$temp_file"
            ((count++))
        fi
    done < "$state_file"
    
    mv "$temp_file" "$state_file"
    
    if [[ $count -ge $MAX_RESTARTS ]]; then
        return 1
    fi
    return 0
}

# Record a restart attempt
record_restart() {
    local service="$1"
    local state_file="$STATE_DIR/${service}_restarts"
    echo "$(date +%s)" >> "$state_file"
}

# Check certificate expiration
check_certificates() {
    log "INFO" "Checking certificate expiration..."
    
    for cert_file in "${CERT_FILES[@]}"; do
        local cert_path="$CERT_PATH/$cert_file"
        
        if [[ ! -f "$cert_path" ]]; then
            send_alert "Certificate Missing" "Certificate file not found: $cert_path" "high"
            continue
        fi
        
        # Get expiration date
        local expiry_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
        if [[ -z "$expiry_date" ]]; then
            send_alert "Certificate Error" "Cannot read certificate: $cert_path" "high"
            continue
        fi
        
        # Calculate days until expiration
        local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        
        log "INFO" "Certificate $cert_file expires in $days_left days"
        
        if [[ $days_left -le $CERT_CRITICAL_DAYS ]]; then
            send_alert "Certificate CRITICAL" "Certificate $cert_file expires in $days_left days!" "urgent"
        elif [[ $days_left -le $CERT_WARN_DAYS ]]; then
            send_alert "Certificate Warning" "Certificate $cert_file expires in $days_left days" "high"
        fi
    done
}

# Layered nginx health check
check_nginx_health() {
    local status=0
    
    # Layer 1: Is the process running?
    if ! systemctl is-active --quiet nginx; then
        log "ERROR" "Nginx process is not running"
        return 1
    fi
    
    # Layer 2: Is it responding to HTTP requests?
    if ! curl -sf --max-time 5 http://127.0.0.1:80 > /dev/null 2>&1; then
        # Try once more after a short delay
        sleep 2
        if ! curl -sf --max-time 5 http://127.0.0.1:80 > /dev/null 2>&1; then
            log "ERROR" "Nginx is not responding to HTTP requests"
            return 2
        fi
    fi
    
    log "INFO" "Nginx health check passed"
    return 0
}

# Check service status
check_service() {
    local service="$1"
    
    if systemctl is-active --quiet "$service"; then
        log "INFO" "Service $service is running"
        return 0
    else
        log "ERROR" "Service $service is not running"
        return 1
    fi
}

# Safe restart with config validation (for nginx)
safe_restart_nginx() {
    # Validate nginx config before restart
    if ! nginx -t 2>/dev/null; then
        send_alert "Nginx Config Error" "Nginx configuration is invalid, cannot restart safely" "urgent"
        return 1
    fi
    
    # Check rate limit
    if ! can_restart "nginx"; then
        send_alert "Nginx Rate Limit" "Nginx restart rate limit exceeded ($MAX_RESTARTS restarts in $((RESTART_WINDOW/60)) minutes). Manual intervention required." "urgent"
        return 1
    fi
    
    # Perform restart
    record_restart "nginx"
    log "INFO" "Restarting nginx..."
    
    if systemctl restart nginx; then
        sleep 2
        if check_nginx_health; then
            send_alert "Nginx Recovered" "Nginx was down and has been successfully restarted" "default"
            return 0
        fi
    fi
    
    send_alert "Nginx Restart Failed" "Failed to restart nginx, manual intervention required" "urgent"
    return 1
}

# Safe restart for other services
safe_restart_service() {
    local service="$1"
    
    # Check rate limit
    if ! can_restart "$service"; then
        send_alert "Service Rate Limit" "Service $service restart rate limit exceeded. Manual intervention required." "urgent"
        return 1
    fi
    
    # Perform restart
    record_restart "$service"
    log "INFO" "Restarting $service..."
    
    if systemctl restart "$service"; then
        sleep 2
        if check_service "$service"; then
            send_alert "Service Recovered" "Service $service was down and has been successfully restarted" "default"
            return 0
        fi
    fi
    
    send_alert "Service Restart Failed" "Failed to restart $service, manual intervention required" "urgent"
    return 1
}

# Main monitoring function
monitor_services() {
    log "INFO" "Starting service monitoring..."
    
    # Check nginx with layered health check
    if ! check_nginx_health; then
        safe_restart_nginx
    fi
    
    # Check other services
    for service in "${SERVICES[@]}"; do
        if [[ "$service" == "nginx" ]]; then
            continue  # Already handled above
        fi
        
        if ! check_service "$service"; then
            safe_restart_service "$service"
        fi
    done
}

# Disk space check (certificates fail to renew if disk full)
check_disk_space() {
    local usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    
    if [[ $usage -ge 90 ]]; then
        send_alert "Disk Space Critical" "Disk usage at ${usage}%, certificate renewal may fail!" "high"
    elif [[ $usage -ge 80 ]]; then
        log "WARN" "Disk usage at ${usage}%"
    else
        log "INFO" "Disk usage at ${usage}%"
    fi
}

# Main execution
main() {
    log "INFO" "======== Monitor Script Started ========"
    
    check_certificates
    monitor_services
    check_disk_space
    
    log "INFO" "======== Monitor Script Completed ========"
}

# Run main function
main
