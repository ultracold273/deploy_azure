#!/bin/bash
set -euo pipefail

PORT=$1
PASSKEY=$2

if [[ -z $PORT ]]; then
    echo Please enter the port the server will use.
    exit 1
fi

if [[ -z $PASSKEY ]]; then
    echo Please pass a password.
    exit 1
fi

if [[ $(id -u) != 0 ]]; then
    echo Please run this script as root.
    exit 1
fi

if [[ $(uname -m 2> /dev/null) != x86_64 ]]; then
    echo Please run this script on x86_64 machine.
    exit 1
fi

NAME=shadowsocks
VERSION=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | sed -E 's/.*"v(.*)".*/\1/')
TARBALL="$NAME-v$VERSION.x86_64-unknown-linux-musl.tar.xz"
DOWNLOADURL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v$VERSION/$TARBALL"
TMPDIR="$(mktemp -d)"
INSTALLPREFIX=/usr/local
SYSTEMDPREFIX=/usr/lib/systemd/system

BINARYPREFIX="$INSTALLPREFIX/bin"
CONFIGPATH="$INSTALLPREFIX/etc/$NAME/config.json"
SYSTEMDPATH="$SYSTEMDPREFIX/$NAME.service"

echo Entering temp directory $TMPDIR...
cd "$TMPDIR"

echo Downloading $NAME $VERSION...
curl -LO --progress-bar "$DOWNLOADURL" || wget -q --show-progress "$DOWNLOADURL"

echo Unpacking $NAME $VERSION...
tar xf "$TARBALL"

echo Installing $NAME Binaries to $BINARYPREFIX
BINARY=("sslocal" "ssserver" "ssservice" "ssmanager" "ssurl")
for bname in "${BINARY[@]}"; do
    echo Installing $bname to "$BINARYPREFIX/$bname"
    install -Dm755 "$bname" "$BINARYPREFIX/$bname"
done

BINARYPATH="$BINARYPREFIX/ssservice"

EXAMPLEPATH="server.json"
echo Installing $NAME server config to $CONFIGPATH
if ! [[ -f "$CONFIGPATH" ]]; then
    cat > "$EXAMPLEPATH" << EOF
{
    "server": "0.0.0.0",
    "server_port": $PORT,
    "password": "$PASSKEY",
    "timeout": 60,
    "method": "chacha20-ietf-poly1305",
    "fast_open": false
}
EOF
    install -Dm644 "$EXAMPLEPATH" "$CONFIGPATH"
fi

if [[ -d $SYSTEMDPREFIX ]]; then
    echo Installing $NAME systemd service to $SYSTEMDPATH...
    if ! [[ -f "$SYSTEMDPATH" ]]; then
        cat > "$SYSTEMDPATH" << EOF
[Unit]
Description=$NAME
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network.target

[Service]
Type=simple
ExecStart="$BINARYPATH" server -c "$CONFIGPATH"
DynamicUser=yes
LimitNOFILE=32768

[Install]
WantedBy=multi-user.target
EOF
        echo Reloading systemd daemon...
        systemctl daemon-reload
    else
        echo Skipping installing $NAME systemd service...
    fi
fi

echo Deleting temp directory $TMPDIR...
rm -rf "$TMPDIR"

echo Done!