Vagrant.configure("2") do |config|
  config.vm.box = "perk/ubuntu-2204-arm64"

  config.vm.provider "qemu" do |qe|
    # qe.arch = "amd64"
    # qe.machine = "q35"
  end

  config.vm.synced_folder ".", "/home/vagrant/containerz", type: "rsync"

  # Install Zig and lib6-dev on VM, setup a filesystem that will be used by containerz
  # the shell script can be found at ./utils/vagrant_setup.sh
  config.vm.provision "shell" do |s|
    # TODO: set the correct permission on gneric_fs dir
    s.inline = "bash /home/vagrant/containerz/utils/vagrant_setup.sh"
  end
end
