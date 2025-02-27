all: # need to dfine

create-vagrant-vm:
	vagrant up

destroy-vagrant-vm:
	vagrant destroy --force # force is used to not show a prompt if we are show to destroy the VM

vagrant-ssh:
	vagrant ssh

recreate-vagrant-vm: destroy-vagrant-vm
	@sleep 5			# We set a sleep to make sure that the VM was destroyed, and that there's no config left before recreating
	$(MAKE) create-vagrant-vm

create-generic-fs:
	./utils/create_generic_fs.sh
