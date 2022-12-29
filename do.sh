#!/bin/bash

set -euo pipefail

INSTANCE_NAME=vpn
WG_PORT=43517
CLIENTS=1
IP_ADDRESS_PREFIX=192.168.55
QR_CODE_COUNT=0
CLEANUP_REQUIRED=0

usage() {
    echo "Usage: $0 [-c <1-254>] [-p <1-65535>] [-a <ip-prefix>] [-q <0-254>]" 1>&2
    echo "" 1>&2
    echo "  -d    delete old vpn instance before the configuration" 1>&2
    echo "  -c    the number of clients (default is $CLIENTS)" 1>&2
    echo "  -p    the UDP port for the incoming connections (default is $WG_PORT)" 1>&2
    echo "  -a    the IP network to use, first three octets (default is $IP_ADDRESS_PREFIX)" 1>&2
    echo "  -q    how many configs needs to be displayed as QR code (useful for mobile clients; default is 0)" 1>&2
    exit 1
}

deleteInstance() {
    yc compute instance delete "$INSTANCE_NAME"
}

while getopts ":c:p:a:q:d" o; do
    case "${o}" in
        c)
            CLIENTS=${OPTARG}

            if ! ([[ $CLIENTS -gt 0 ]] && [[ $CLIENTS -lt 255 ]])
            then
                echo "Incorrect value for argument -c!" 1>&2
                echo "" 1>&2

                usage
            fi
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
        d)
            CLEANUP_REQUIRED=1
            ;;
        *)
            usage
            ;;
    esac
done

if ! ([[ $QR_CODE_COUNT -ge 0 ]] && [[ $QR_CODE_COUNT -le $CLIENTS ]])
then
    echo "Incorrect value for argument -q!" 1>&2
    echo "" 1>&2

    usage
fi

shift $((OPTIND-1))

if [ "$CLEANUP_REQUIRED" -eq 1 ]
then
    echo "Deleting the old $INSTANCE_NAME server..."
    deleteInstance
fi

echo 'Booting up a new server...'

ip=$(yc compute instance create --name $INSTANCE_NAME \
    --zone ru-central1-a \
    --ssh-key ~/.ssh/id_rsa.pub \
    --public-ip \
    --create-boot-disk "name=vpn-disk,auto-delete=true,size=5,image-folder-id=standard-images,image-family=ubuntu-2204-lts" \
    --platform standard-v3 \
    --memory 1 \
    --cores 2 \
    --core-fraction 20 \
    --preemptible \
    | grep -FA2 'one_to_one_nat:' | grep -F 'address:' | sed 's/[[:space:]]*address:[[:space:]]*//g')

echo "New instance IP address: $ip"

echo -n 'Configuring the server...'

sleep 30 # Waiting a few seconds to give the server a chance to boot up

ssh -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@$ip >/dev/null 2>&1 <<END
sudo bash -eux <<SUDO
apt update
apt install -y wireguard qrencode
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p

mkdir -p /etc/wireguard

umask 077
wg genkey | tee /etc/wireguard/wg0_privatekey | wg pubkey > /etc/wireguard/wg0_publickey

cat > /etc/wireguard/wg0.conf <<WG
[Interface]
PrivateKey = \\\$(cat /etc/wireguard/wg0_privatekey)
ListenPort = $WG_PORT
Address = ${IP_ADDRESS_PREFIX}.1/24
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

WG

for i in \\\$(seq 1 $CLIENTS)
do
    wg genkey | tee /etc/wireguard/wg0_client\\\${i}_privatekey | wg pubkey > /etc/wireguard/wg0_client\\\${i}_publickey
    cat >> /etc/wireguard/wg0.conf <<WG
[Peer]
PublicKey = \\\$(cat /etc/wireguard/wg0_client\\\${i}_publickey)
AllowedIPs = ${IP_ADDRESS_PREFIX}.\\\$((i+1))/32
PersistentKeepalive = 30

WG
done

systemctl enable wg-quick@wg0.service
systemctl start wg-quick@wg0
SUDO
END

echo 'done!'

for i in $(seq 1 "$CLIENTS")
do
    echo "Copy the following config to the client#${i}"
    cfg=$(cat <<CFG
[Interface]
Address = ${IP_ADDRESS_PREFIX}.$((i+1))/24
DNS = 8.8.8.8
PrivateKey = $(ssh -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} sudo cat /etc/wireguard/wg0_client${i}_privatekey 2>/dev/null)

[Peer]
PublicKey = $(ssh -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} sudo cat /etc/wireguard/wg0_publickey 2>/dev/null)
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ip}:${WG_PORT}
PersistentKeepalive = 30


CFG
)
    if [ $i -le $QR_CODE_COUNT ]
    then
        echo ''
        echo "$cfg" | ssh -T -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" yc-user@${ip} qrencode -t ansiutf8 2>/dev/null
    else
        echo ''
        echo "$cfg"
    fi
done

echo 'Press enter to remove the created instance, or Ctrl+C to keep at alive.'

read

echo 'Removing the instance... '
deleteInstance
