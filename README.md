# containerz

It's a project to implement simple concepts of linux containerz. This implementation is done in Zig.

## Set Up

If you are in a MacOS, you will need to setup a linux VM to run and test this project.
Since MacOS doesn't support Linux namespaces (unshare),
it doesn't have chroot in the same way as Linux, besides Cgroups being a Linux feature.

```
# install VM solution
brew install qemu

# install Vagrant with QEMU support
brew install --cask vagrant
vagrant plugin install vagrant-qemu
```
