# Baytaar MultiWAN as an OpenWrt package: one package for every router (scripts and web pages only, PKGARCH all).
# Built with the OpenWrt SDK (see .github/workflows/openwrt-package.yml): .apk for OpenWrt 25.x, .ipk for 24.10.
# files/ is filled by openwrt/stage_root.py from the same bundle the website serves (build_fw.py), so the package and
# the website upgrade always install the same software.

include $(TOPDIR)/rules.mk

PKG_NAME:=baytaar-multiwan
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Baytaar

include $(INCLUDE_DIR)/package.mk

define Package/baytaar-multiwan
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Baytaar MultiWAN: multi-line failover, admin panel, website link
  DEPENDS:=+mwan3 +curl +nlbwmon +conntrack +uhttpd +jsonfilter +ip-full
  PKGARCH:=all
endef

define Package/baytaar-multiwan/description
  Several internet lines with failover (mwan3), a web panel on port 8080, site and app blocking, free time and
  breaks, sign-in for new devices, per-device limits, Router 2 / node / mesh / repeater modes, a daily backup and a
  link to a Baytaar website account. Works on any OpenWrt router: ports and radios are read from /etc/board.json.
  After installing, run baytaar-setup over SSH (or open http://<router>:8080).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/baytaar-multiwan/install
	$(CP) ./files/* $(1)/
endef

define Package/baytaar-multiwan/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
sh /usr/lib/mwadmin/setup.sh "$(PKG_VERSION)-$(PKG_RELEASE)-pkg"
echo "Baytaar MultiWAN installed. Set it up with:  baytaar-setup   (or open http://<this router>:8080)"
exit 0
endef

define Package/baytaar-multiwan/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
for s in mwsite mwblock mwevents mwrelay mwexempt mwdrive mwremote mwadmin; do
	[ -x /etc/init.d/$$s ] && { /etc/init.d/$$s stop; /etc/init.d/$$s disable; } >/dev/null 2>&1
done
exit 0
endef

$(eval $(call BuildPackage,baytaar-multiwan))
