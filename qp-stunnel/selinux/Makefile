# SELinux policy module build for qp-stunnel.
#
# Uses refpolicy's devel Makefile (from selinux-policy-devel, present in the
# fedora toolbox) to compile qp_stunnel.te + qp_stunnel.fc into qp_stunnel.pp,
# loadable via `semodule -i qp_stunnel.pp`.
#
# Install:  sudo semodule -i qp_stunnel.pp
# Remove:   sudo semodule -r qp_stunnel
# Status:   semodule -l | grep qp_stunnel

include /usr/share/selinux/devel/Makefile
