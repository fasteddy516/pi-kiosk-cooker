#!/bin/bash

echo "Preparing first-boot setup for cloning Raspberry Pi image..."

# Check if the script is running as root
if [ "$EUID" -ne 0 ]; then
  echo "! This script requires root privileges. Please run as root or with sudo."
  exit 1
fi

# Check if rc.local has been configured correctly by the kiosk_cooker.sh script


# set default script-deletion value if it hasn't been defined already
if [ ! -v delete_script ]; then
  delete_script=1
fi

# set default shutdown-on-completion value if it hasn't been defined already
if [ ! -v shutdown_on_complete ]; then
  shutdown_on_complete=1
fi

# set default network-deletion value if it hasn't been defined already
if [ ! -v delete_networks ]; then
  delete_networks=1
fi

# Process command-line arguments
for arg in "$@"; do
  if [[ "$arg" == "--no-delete" ]]; then
    echo "@ Skipping script delete on completion."
    delete_script=0
  fi
  if [[ "$arg" == "--no-shutdown" ]]; then
    echo "@ Skipping shutdown on script completion."
    shutdown_on_complete=0
  fi
  if [[ "$arg" == "--preserve-networks" ]]; then
    echo "@ Skipping deletion of network connections."
    delete_networks=0
  fi
done

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

# Clear systemd journal logs
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

# Deleting SSH host keys
echo -n "> Deleting SSH host keys..."
sudo rm -f /etc/ssh/ssh_host_*
echo "DONE"

# Clear systemd journal logs
echo -n "> Clearing systemd journal logs..."
sudo rm -rf /var/log/journal/*
echo "DONE"

# Delete network connections if requested
if [ $delete_networks -eq 1 ]; then
  echo -n "> Deleting network connections..."
  sudo rm /etc/NetworkManager/system-connections/*.nmconnection
  echo "DONE"
fi

# Create/replace rc.local script if needed
if [[ ! -e "/etc/rc.local" ]] || ! grep -q "first-boot.sh" "/etc/rc.local"; then
  echo -n "> Configuring rc.local script..."
  cat << 'EOF' > /etc/rc.local
#!/bin/bash

# Check if the first-boot script exists before executing
if [ -x /usr/local/bin/first-boot.sh ]; then
  echo "* Running first-boot.sh script"
  /usr/local/bin/first-boot.sh
  echo "* First-boot.sh script completed"
else
  echo "@ first-boot.sh script not found or not executable, skipping"
fi

exit 0
EOF
  chmod +x /etc/rc.local
  echo "DONE"
else
  echo "@ rc.local script already configured for first-boot.sh"
fi

# Delete this script after execution so that it doesn't become part of a cloned image
if [ $delete_script -eq 1 ]; then
  if [[ "$0" != "bash" ]]; then
    echo -n "> Deleting cloning preparation script..."
    rm -- "$0"
    echo "DONE"
  fi
fi

# all done - countdown to shutdown
if [ $shutdown_on_complete -eq 1 ]; then
  echo "* Cloning preparation complete. The system will now shut down."
  echo ""
  for i in `seq 30 -1 1` ; do echo -ne "\r*** Shutting down in $i seconds.  (CTRL-C to cancel) ***" ; sleep 1 ; done
  poweroff
else
  echo "* Cloning preparation complete. Shutdown was skipped, so the system will remain running."
  echo ""
fi
