Vagrant.configure("2") do |config|
  config.vm.box = "perk/ubuntu-2204-arm64"

  config.vm.provider "qemu" do |qe|
    # qe.arch = "amd64"
    # qe.machine = "q35"
  end

  config.vm.synced_folder ".", "/home/vagrant/containerz", type: "rsync"

  # Install Zig on VM, the shell script can be found at ./install_zig.sh
  config.vm.provision "shell" do |s|
    s.inline = "sudo snap install zig --beta --classic && sudo apt install libc6-dev -y"
  end
end
