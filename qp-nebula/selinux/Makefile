# SELinux policy module build for qp-nebula.
#
# Uses refpolicy's devel Makefile (from selinux-policy-devel, present in the
# fedora toolbox) to compile qp_nebula.te + qp_nebula.fc into qp_nebula.pp,
# loadable via `semodule -i qp_nebula.pp`.
#
# Install:  sudo semodule -i qp_nebula.pp
# Remove:   sudo semodule -r qp_nebula
# Status:   semodule -l | grep qp_nebula

include /usr/share/selinux/devel/Makefile
