# Quick VPN with Yandex Cloud

## What is it?

There're days, when you need to access a web-site hosted in Russia, which has prevented the out-of-the-country access.
Unfortunately, some of the utility providers do this, yet you still need to pay for the utilities when you have fled
the country.

Yandex.Cloud allows you to create a low-cost preemptive virtual machine for under a rouble per hour. Instruction and the
script in this repo help you create such a virtual machine.

## How to prepare?

1. Set up Yandex Cloud account.
2. Configure the [billing account in Yandex Cloud](https://console.cloud.yandex.ru/billing/create-account).
3. Install [yc](https://cloud.yandex.com/en/docs/cli/quickstart).
4. Restart your shell to make `yc` command available.
5. Configure `yc` by calling `yc init`.
6. [Install Wireguard](https://www.wireguard.com/install/) on the device where you want to use VPN.
7. Ensure you have an SSH-key generated, with public key saved as `~/.ssh/id_rsa.pub`.
8. Download [do.sh](./do.sh) and run it, following the on-screen instructions. Keep the script running for now.
9. Configure your WireGuard client using the config displayed by the script.
10. When you're finished, press Enter in the terminal where you have the script running. It should remove the created virtual machine. Check that the server was removed from [Yandex Cloud](https://console.cloud.yandex.ru/).

By default the command will generate a wireguard config for 1 client, using the
subnet `192.168.55.0/24`. You can override the defaults by calling the script
with the arguments: `./do.sh 10 10.0.0` — this will generate config for 10
clients with subnet `10.0.0.0/24`.

Below is the example produced by this script (so you'll know what to look for in
the output):

```ini
[Interface]
Address = 10.10.10.2/24
DNS = 8.8.8.8
PrivateKey = cGiXg4D1SHlvyxqRCeuwxXil9UeMgdfw4WqqNwvZ+ls=

[Peer]
PublicKey = WtPF2qWwDlGSjfo0SJu3kr6FeB/csBXBmD+L72/j8mc=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 62.84.2.1:43517
PersistentKeepalive = 30
```

You need to add this config into your wireguard client and activate the connection.
