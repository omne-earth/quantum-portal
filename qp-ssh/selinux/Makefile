# SELinux policy module build for qp-ssh.
#
# Uses refpolicy's devel Makefile (from selinux-policy-devel, present in the
# fedora toolbox) to compile qp_ssh.te + qp_ssh.fc into qp_ssh.pp, loadable via
# `semodule -i qp_ssh.pp`.
#
# Install:  sudo semodule -i qp_ssh.pp
# Remove:   sudo semodule -r qp_ssh
# Status:   semodule -l | grep qp-ssh

include /usr/share/selinux/devel/Makefile
