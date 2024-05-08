#!/bin/bash

echo "Preparing first-boot setup for cloning Raspberry Pi image..."

# Create first-boot script
echo -n "> Creating /usr/local/bin/first-boot.sh script..."
cat << 'EOF' > /usr/local/bin/first-boot.sh
#!/bin/bash

# Clear the old machine-id
sudo rm -f /etc/machine-id
sudo systemd-machine-id-setup

# Delete SSH host keys
sudo rm -f /etc/ssh/ssh_host_*

# Generate new SSH host keys
sudo ssh-keygen -A

# Set a unique hostname using the last three octets of the MAC address for eth0
LAST_OCTETS=$(ip link show eth0 | awk '/ether/ {print $2}' | awk -F: '{printf "%s%s%s", $4, $5, $6}')
NEW_HOSTNAME="raspberrypi-$LAST_OCTETS"
echo "$NEW_HOSTNAME" | sudo tee /etc/hostname
sudo sed -i "s/127.0.1.1.*/127.0.1.1 $NEW_HOSTNAME/" /etc/hosts

# Clear systemd journal logs (optional)
sudo rm -rf /var/log/journal/*

# Log completion of the first boot tasks
echo "First boot setup completed!"

# Delete this script after execution
rm /usr/local/bin/first-boot.sh

# Reboot the system after completing first-boot setup
sudo reboot
EOF
chmod +x /usr/local/bin/first-boot.sh
echo "DONE"

# Create/replace rc.local script
echo -n "> Configuring /etc/rc.local script..."
cat << 'EOF' > /etc/rc.local
#!/bin/bash

# Check if the first-boot script exists before executing
if [ -x /usr/local/bin/first-boot.sh ]; then
  /usr/local/bin/first-boot.sh
fi

exit 0
EOF
chmod +x /etc/rc.local
echo "DONE"

# Delete this script after execution so that it doesn't become part of a cloned image
if [[ "$0" != "bash" ]]; then
  echo -n "> Deleting cloning preparation script..."
  rm -- "$0"
  echo "DONE"
fi

# Power off the system - it is ready to have the micro sd card removed and imaged
poweroff