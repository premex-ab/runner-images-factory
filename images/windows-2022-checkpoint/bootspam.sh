#!/bin/bash
# Dismiss the UEFI "Press any key to boot from CD or DVD" prompt by spamming Enter
# over VNC through the whole boot window. Packer's one-shot boot_command can't
# reliably hit the ~5s prompt window, so an external loop does it. Finds the
# Packer build VM's VNC port from the qemu cmdline (the one with OVMF efivars).
port=""
for i in $(seq 1 40); do
  for pid in $(pgrep qemu-system); do
    c=$(tr "\0" "\n" < /proc/$pid/cmdline 2>/dev/null)
    echo "$c" | grep -q efivars || continue
    disp=$(echo "$c" | grep -A1 '^-vnc' | tail -1); n=${disp##*:}; port=$((5900 + n))
  done
  [ -n "$port" ] && break
  sleep 1
done
[ -z "$port" ] && { echo "bootspam: no packer qemu vnc port found"; exit 1; }
# Only spam the boot-prompt window (~first 20s). The prompt shows once, early, and
# times out in ~5s; spamming longer reaches the installer UI and can hit a button
# (e.g. Cancel -> a "quit?" dialog that pauses Setup). On the install's later reboots
# the prompt just times out and boots from disk — no keypress wanted there.
echo "bootspam: sending Enter to vnc $port for ~20s (boot-prompt window only)"
for i in $(seq 1 10); do
  ~/.local/bin/vncdo -s "127.0.0.1::$port" key enter 2>/dev/null
  sleep 2
done
echo "bootspam: done"
