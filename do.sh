#!/bin/bash

set -euo pipefail

INSTANCE_NAME=vpn
WG_PORT=43517
CLIENTS=1
CLIENTS_COUNT_PROVIDED=0
IP_ADDRESS_PREFIX=192.168.55
QR_CODE_COUNT=0
CLEANUP_REQUIRED=0
REDIRECT_ERRORS_CONFIG='2>&1'
OUTPUT_CONFIG='>/dev/null 2>&1'
CONNECTION_ATTEMPTS=12
ATTEMPT_TIMEOUT=5

usage() {
    echo "Usage: $0 [-c <1-254>] [-p <1-65535>] [-a <ip-prefix>] [-q <0-254>]" 1>&2
    echo "" 1>&2
    echo "  -d    delete old vpn instance before the configuration" 1>&2
    echo "  -c    the number of clients (default is $CLIENTS)" 1>&2
    echo "  -p    the UDP port for the incoming connections (default is $WG_PORT)" 1>&2
    echo "  -a    the IP network to use, first three octets (default is $IP_ADDRESS_PREFIX)" 1>&2
    echo "  -q    how many configs needs to be displayed as QR code (useful for mobile clients; default is 0)" 1>&2
    echo "  -v    verbose output" 1>&2
    echo "  -i    initial connection attempts (default is $CONNECTION_ATTEMPTS)" 1>&2
    echo "  -t    attempt timeout in seconds (default is $ATTEMPT_TIMEOUT)" 1>&2
    exit 1
}

deleteInstance() {
    yc compute instance delete "$INSTANCE_NAME"
}

while getopts ":c:p:a:q:i:t:dv" o; do
    case "${o}" in
        c)
            CLIENTS=${OPTARG}

            if ! ([[ $CLIENTS -gt 0 ]] && [[ $CLIENTS -lt 255 ]])
            then
                echo "Incorrect value for argument -c!" 1>&2
                echo "" 1>&2

                usage
            fi

            CLIENTS_COUNT_PROVIDED=1
            ;;
        p)
            WG_PORT=${OPTARG}

            if ! ([[ $WG_PORT -gt 0 ]] && [[ $WG_PORT -lt 65536 ]])
            then
                echo "Incorrect value for argument -p!" 1>&2
                echo "" 1>&2

                usage
            fi
            ;;
        a)
            IP_ADDRESS_PREFIX=${OPTARG}
            ;;
        q)
            QR_CODE_COUNT=${OPTARG}
            ;;
        i)
            CONNECTION_ATTEMPTS=${OPTARG}
            ;;
        t)
            ATTEMPT_TIMEOUT=${OPTARG}
            ;;
        d)
            CLEANUP_REQUIRED=1
            ;;
        v)
            REDIRECT_ERRORS_CONFIG=''
            OUTPUT_CONFIG=''
            ;;
        *)
            usage
            ;;
    esac
done

if ! ([[ $QR_CODE_COUNT -ge 0 ]] && [[ $QR_CODE_COUNT -le $CLIENTS ]])
then
    if [ "$CLIENTS_COUNT_PROVIDED" -eq 0 ]
    then
        CLIENTS=$QR_CODE_COUNT
    else
        echo "Incorrect value for argument -q!" 1>&2
        echo "Number of QR codes should NOT be greater than number of client" 1>&2
        echo "Given arguments: QR codes count $QR_CODE_COUNT, clients count $CLIENTS" 1>&2
        echo "" 1>&2
        usage
    fi
fi

if ! which yc >/dev/null 2>&1
then
    echo "Please install the Yandex Cloud CLI interface: https://cloud.yandex.com/en/docs/cli/quickstart."
    exit 1
fi

if ! yc config get cloud-id > /dev/null 2>&1
then
    echo "Please ensure that you've initialized the Yandex Cloud CLI tool with 'yc init'."
    exit 1
fi

if ! [ -f ~/.ssh/id_rsa.pub ]
then
    echo "Please generate an RSA ssh-key, storing the public key in '$HOME/.ssh/id_rsa.pub'."
    exit 1
fi

shift $((OPTIND-1))

if [ "$CLEANUP_REQUIRED" -eq 1 ]
then
    echo "Deleting the old $INSTANCE_NAME server..."
    deleteInstance || true
fi

echo 'Booting up a new server...'

ip=$(yc compute instance create --name $INSTANCE_NAME \
    --zone ru-central1-a \
    --ssh-key ~/.ssh/id_rsa.pub \
    --public-ip \
    --create-boot-disk "name=vpn-disk,auto-delete=true,size=8,image-folder-id=standard-images,image-family=ubuntu-2204-lts" \
    --platform standard-v3 \
    --memory 1 \
    --cores 2 \
    --core-fraction 20 \
    --preemptible \
    | grep -FA2 'one_to_one_nat:' | grep -F 'address:' | sed 's/[[:space:]]*address:[[:space:]]*//g')

echo "New instance IP address: $ip"

echo -n 'Waiting for the server to boot... '

attempts=0
last_attempt_start=$(date +%s)

# Waiting a few seconds to give the server a chance to boot up
while ! ssh -o LogLevel=ERROR -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=$ATTEMPT_TIMEOUT" yc-user@$ip whoami >/dev/null 2>&1
do
    time_from_attempt_start=$(($(date +%s)-$last_attempt_start))
    attempts=$((attempts+1))

    if [ "$attempts" -ge "$CONNECTION_ATTEMPTS" ]
    then
        echo "Server connection timed out. Try running the script with a higher initial connection attempts value." >&2
        exit 2
    fi

    if [ "$time_from_attempt_start" -lt "$ATTEMPT_TIMEOUT" ]
    then
        sleep $((ATTEMPT_TIMEOUT-time_from_attempt_start))
    fi

    last_attempt_start=$(date +%s)
done

echo 'done!'

echo -n 'Configuring the server... '

if ! ssh -o LogLevel=ERROR -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@$ip "sudo bash -eux $OUTPUT_CONFIG" <<END
# Wait for server to finish booting
while ps waux | egrep -q '/[u]sr/bin/cloud-init' || ps waux | egrep -q '/[u]sr/lib/ubuntu-release-upgrader/check-new-release'
do
    sleep 5
done

ps wauxf

apt-get update
apt-get install -y wireguard qrencode
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p

mkdir -p /etc/wireguard

umask 077
wg genkey | tee /etc/wireguard/wg0_privatekey | wg pubkey > /etc/wireguard/wg0_publickey

cat > /etc/wireguard/wg0.conf <<WG
[Interface]
PrivateKey = \$(cat /etc/wireguard/wg0_privatekey)
ListenPort = $WG_PORT
Address = ${IP_ADDRESS_PREFIX}.1/24
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

WG

for i in \$(seq 1 $CLIENTS)
do
    wg genkey | tee /etc/wireguard/wg0_client\${i}_privatekey | wg pubkey > /etc/wireguard/wg0_client\${i}_publickey
    cat >> /etc/wireguard/wg0.conf <<WG
[Peer]
PublicKey = \$(cat /etc/wireguard/wg0_client\${i}_publickey)
AllowedIPs = ${IP_ADDRESS_PREFIX}.\$((i+1))/32
PersistentKeepalive = 30

WG
done

systemctl enable wg-quick@wg0.service
systemctl start wg-quick@wg0
END
then
    server_init_result=$?
    if [ "$OUTPUT_CONFIG" = "" ]
    then
        echo 'failed! Deleting the server now...'
    else
        echo 'failed! Run the script with `-v` argument to check the details. Deleting the server now...'
    fi
    deleteInstance
    exit $server_init_result
fi

echo 'done!'

for i in $(seq 1 "$CLIENTS")
do
    echo "Copy the following config to the client#${i}"
    cfg=$(cat <<CFG
[Interface]
Address = ${IP_ADDRESS_PREFIX}.$((i+1))/24
DNS = 8.8.8.8
PrivateKey = $(ssh -o LogLevel=ERROR -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} sudo cat /etc/wireguard/wg0_client${i}_privatekey $REDIRECT_ERRORS_CONFIG)

[Peer]
PublicKey = $(ssh -o LogLevel=ERROR -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} sudo cat /etc/wireguard/wg0_publickey $REDIRECT_ERRORS_CONFIG)
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ip}:${WG_PORT}
PersistentKeepalive = 30


CFG
)
    if [ $i -le $QR_CODE_COUNT ]
    then
        echo ''
        echo "$cfg" | ssh -o LogLevel=ERROR -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} qrencode -t ansiutf8 $REDIRECT_ERRORS_CONFIG
    else
        echo ''
        echo "$cfg"
    fi
done

echo 'Press enter to remove the created instance, or Ctrl+C to keep at alive.'

read

echo 'Removing the instance... '
deleteInstance
