install: src/owncloud-uploader.pl systemd/owncloud-uploader.service
	install -d $(HOME)/bin
	install -m 0755 src/owncloud-uploader.pl $(HOME)/bin/owncloud-uploader.pl
	install -d $(HOME)/.config/systemd/user
	sed s~__HOME__~$(HOME)~ systemd/owncloud-uploader.service > $(HOME)/.config/systemd/user/owncloud-uploader.service
	systemctl --user daemon-reload
	systemctl --user enable owncloud-uploader
	install -d $(HOME)/.config/owncloud-uploader
	test -f $(HOME)/.config/owncloud-uploader/config || install -m 0644 config/config $(HOME)/.config/owncloud-uploader/config
	test -f $(HOME)/.config/owncloud-uploader/log4perl.conf || install -m 0644 config/log4perl.conf $(HOME)/.config/owncloud-uploader/log4perl.conf

.PHONY: install
