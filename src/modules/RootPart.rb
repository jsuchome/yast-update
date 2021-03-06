# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2006-2012 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------

# Module:	RootPart.ycp
#
# Authors:	Arvin Schnell <arvin@suse.de>
#
# Purpose:	Responsible for searching of root partitions and
#		mounting of target partitions.
#
# $Id$
require "yast"

module Yast
  class RootPartClass < Module
    def main
      Yast.import "UI"

      textdomain "update"

      Yast.import "Directory"
      Yast.import "Mode"
      Yast.import "Linuxrc"
      Yast.import "Storage"
      Yast.import "Popup"
      Yast.import "ModuleLoading"
      Yast.import "FileSystems"
      Yast.import "Update"
      Yast.import "OSRelease"
      Yast.import "FileUtils"
      Yast.import "Arch"
      Yast.import "String"
      Yast.import "Installation"
      Yast.import "Report"
      Yast.import "Label"
      Yast.import "Stage"
      Yast.import "Wizard"

      Yast.include self, "partitioning/custom_part_dialogs.rb"


      # Selected root partition for the update or boot.
      @selectedRootPartition = ""

      # FATE #301844, to find out that a system for update has been changed
      @previousRootPartition = ""

      # Map of all root partitions (key) and information map (value).
      # The information map contains the keys `valid, `name and `arch.
      @rootPartitions = {}

      # Number of valid root partitions.
      @numberOfValidRootPartitions = 0

      # Show all partitions (not only root partitions) in the dialog.
      @showAllPartitions = false

      # Did we search for root partitions
      @didSearchForRootPartitions = false

      # We successfully mounted the target partitions
      @targetOk = false

      # Did we try to mount the target partitions?
      @did_try_mount_partitions = false

      @already_checked_jfs_partitions = []

      @non_modular_fs = ["proc", "sysfs"]

      # List of mounted partitions, activated swap partitions and loop devices.
      # Amongst other things used for reversing action if mode is changed from
      # update to new installation or if root partition for update is changed.
      # The order of the list if of paramount importance.
      #
      # Each item is list [string value, string type [, string device]] where:
      #
      # Keys/values are:
      #
      #   `type     The type, one of "mount", "swap" or "crypt".
      #
      #   `device   The device.
      #
      #   `mntpt    The mount point, only for `type = "mount".  Does not
      #             include Installation::destdir.
      @activated = []


      #  Link to SDB article concerning renaming of devices.
      @sdb = Builtins.sformat(
        _(
          "See the SDB article at %1 for details\nabout how to solve this problem."
        ),
        "http://support.novell.com/techcenter/sdb/en/2003/03/fhassel_update_not_possible.html"
      )

      # translation from new to old device names
      # such as /dev/sdc4 -> /dev/hdb4
      @backward_translation = {}
    end

    # Returns currently activated partitions.
    #
    # @return [Array<Hash{Symbol => String>}] activated
    def GetActivated
      deep_copy(@activated)
    end

    def Mounted
      Ops.greater_than(Builtins.size(@activated), 0)
    end


    # Get the key what of the selected root partition.
    def GetInfoOfSelected(what)
      i = Ops.get(@rootPartitions, @selectedRootPartition, {})

      if what == :name
        # Name is known
        if Ops.get_string(i, what, "") != ""
          return Ops.get_string(i, what, "") 

          # Linux partition, but no root FS found
        elsif Builtins.contains(
            FileSystems.possible_root_fs,
            Ops.get_symbol(i, :fs, :nil)
          )
          # label - name of sustem to update
          return _("Unknown Linux System") 

          # Non-Linux
        else
          # label - name of sustem to update
          return _("Non-Linux System")
        end
      else
        # label - name of sustem to update
        return Ops.get_locale(i, what, _("Unknown"))
      end
    end


    # Set the selected root partition to some valid one. Only
    # make sense if the number of valid root partition is one.
    def SetSelectedToValid
      @selectedRootPartition = ""
      Builtins.foreach(@rootPartitions) do |p, i|
        if Ops.get_boolean(i, :valid, false) && @selectedRootPartition == ""
          @selectedRootPartition = p
        end
      end

      nil
    end


    #
    def AddToTargetMap
      target_map = Storage.GetOndiskTarget
      Builtins.y2milestone("On disk target map: %1", target_map)
      tmp = Builtins.filter(@activated) do |e|
        Ops.get_string(e, :type, "") == "mount"
      end
      Builtins.foreach(tmp) do |e|
        Builtins.y2milestone(
          "Setting partition data: Device: %1, MountPoint: %2",
          Ops.get_string(e, :device, ""),
          Ops.get_string(e, :mntpt, "")
        )
        target_map = Storage.SetPartitionData(
          target_map,
          Ops.get_string(e, :device, ""),
          "mount",
          Ops.get_string(e, :mntpt, "")
        )
        if Builtins.issubstring(
            Ops.get_string(e, :device, ""),
            "/dev/disk/by-id"
          )
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :id
          )
        elsif Builtins.issubstring(Ops.get_string(e, :device, ""), "/dev/")
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :device
          )
        else
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :label
          )
        end
      end
      tmp = Builtins.filter(@activated) do |e|
        Ops.get_string(e, :type, "") == "swap"
      end
      Builtins.foreach(tmp) do |e|
        Builtins.y2milestone(
          "Setting swap partition data: Device: %1",
          Ops.get_string(e, :device, "")
        )
        target_map = Storage.SetPartitionData(
          target_map,
          Ops.get_string(e, :device, ""),
          "mount",
          "swap"
        )
        if Builtins.issubstring(
            Ops.get_string(e, :device, ""),
            "/dev/disk/by-id"
          )
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :id
          )
        elsif Builtins.issubstring(Ops.get_string(e, :device, ""), "/dev/")
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :device
          )
        else
          target_map = Storage.SetPartitionData(
            target_map,
            Ops.get_string(e, :device, ""),
            "mountby",
            :label
          )
        end
      end
      Builtins.y2milestone("Setting target map: %1", target_map)
      Storage.SetTargetMap(target_map)

      nil
    end


    #
    def RemoveFromTargetMap
      target_map = Storage.GetTargetMap
      tmp = Builtins.filter(@activated) do |e|
        Ops.get_string(e, :type, "") == "mount"
      end
      Builtins.foreach(tmp) do |e|
        target_map = Storage.SetPartitionData(
          target_map,
          Ops.get_string(e, :device, ""),
          "mount",
          ""
        )
      end
      Storage.SetTargetMap(target_map)

      nil
    end

    # Unmount all mounted partitions, deactivate swaps, detach loopback
    # devices. Uses list activated to make actions in reverse order.
    # @param keeep_in_target Do not remove mounts from targetmap
    # @return [void]
    def UnmountPartitions(keep_in_target)
      Builtins.y2milestone("UnmountPartitions: %1", keep_in_target)

      @did_try_mount_partitions = false

      Builtins.foreach(@activated) do |info|
        Builtins.y2milestone("Unmounting %1", info)
        type = Ops.get_string(info, :type, "")
        if type != ""
          if type == "mount"
            file = Ops.add(
              Installation.destdir,
              Ops.get_string(info, :mntpt, "")
            )
            if !Convert.to_boolean(SCR.Execute(path(".target.umount"), file))
              # error report, %1 is device (eg. /dev/hda1)
              Report.Error(
                Builtins.sformat(
                  _(
                    "Cannot unmount partition %1.\n" +
                      "\n" +
                      "It is currently in use. If the partition stays mounted,\n" +
                      "the data may be lost. Unmount the partition manually\n" +
                      "or restart your computer.\n"
                  ),
                  file
                )
              )
            end
          elsif type == "swap"
            device = Ops.get_string(info, :device, "")
            # FIXME? is it safe?
            if SCR.Execute(
                path(".target.bash"),
                Ops.add("/sbin/swapoff ", device)
              ) != 0
              Builtins.y2error("Cannot deactivate swap %1", device)
            end
          elsif type == "crypt"
            dmname = Ops.get_string(info, :device, "")
            dmname = Ops.add(
              "cr_",
              Builtins.substring(
                dmname,
                Ops.add(Builtins.findlastof(dmname, "/"), 1)
              )
            )
            # FIXME? is it safe?
            if WFM.Execute(
                path(".local.bash"),
                Ops.add("cryptsetup remove ", dmname)
              ) != 0
              Builtins.y2error("Cannot remove dm device %1", dmname)
            end
          end
        end
      end

      # now remove the mount points of the mounted partitions
      # in the target map of the storage module
      RemoveFromTargetMap() if !keep_in_target


      # clear activated list
      @activated = []

      nil
    end


    # Add information about mounted partition to internal list.
    # @param [Hash{Symbol => String}] partinfo partinfo has to be list with exactly two strings,
    # see description of list "activated"
    # @return [void]
    def AddMountedPartition(partinfo)
      partinfo = deep_copy(partinfo)
      @activated = Builtins.prepend(@activated, partinfo)
      Builtins.y2debug("adding %1 yields %2", partinfo, @activated)

      nil
    end


    # Check the filesystem of a partition.
    def FSCKPartition(partition)
      if !Mode.test
        detected_fs = Storage.DetectFs(partition)
        if detected_fs == :ext2
          # label, %1 is partition
          out = Builtins.sformat(_("Checking partition %1"), partition)
          UI.OpenDialog(Opt(:decorated), Label(out))

          Builtins.y2milestone("command: /sbin/e2fsck -y %1", partition)
          SCR.Execute(
            path(".target.bash"),
            Ops.add("/sbin/e2fsck -y ", partition)
          )

          UI.CloseDialog
        end
      end

      nil
    end



    # @param [String] headline (optional; to disable, use "")
    # @param [String] question
    # @param string button (true)
    # @param string button (false)
    # @param [String] details (hidden under [Details] button; optional; to disable, use "")
    def AnyQuestionAnyButtonsDetails(headline, question, button_yes, button_no, details)
      has_details = true
      has_details = false if details == "" || details == nil

      has_heading = true
      has_heading = false if headline == "" || headline == nil

      heading = has_heading ? VBox(Left(Heading(headline))) : Empty()

      popup_def = Left(Label(question))

      details_checkbox = has_details ?
        VBox(
          VSpacing(1),
          Left(CheckBox(Id(:details), Opt(:notify), _("Show &Details"), false))
        ) :
        Empty()

      popup_buttons = VBox(
        VSpacing(1),
        HBox(
          HSpacing(8),
          PushButton(Id(:yes), button_yes),
          VSpacing(2),
          PushButton(Id(:cancel), button_no),
          HSpacing(8)
        ),
        VSpacing(0.5)
      )

      UI.OpenDialog(
        Opt(:decorated),
        VSquash(
          VBox(
            heading,
            popup_def,
            Left(Opt(:hstretch), ReplacePoint(Id(:rp_details), Empty())),
            details_checkbox,
            popup_buttons
          )
        )
      )
      UI.SetFocus(Id(:yes))

      userinput = nil
      ret = nil

      while true
        userinput = UI.UserInput

        if userinput == :yes
          ret = true
          break
        elsif userinput == :details
          curr_status = Convert.to_boolean(UI.QueryWidget(Id(:details), :Value))

          if curr_status == false
            UI.ReplaceWidget(Id(:rp_details), Empty())
          else
            UI.ReplaceWidget(
              Id(:rp_details),
              MinSize(
                60,
                10,
                RichText(Id(:details_text), Opt(:plainText, :hstretch), details)
              )
            )
          end
        else
          ret = false
          break
        end
      end

      UI.CloseDialog

      ret
    end

    # Function checks the device and returns whether it is OK or not.
    # The read-only FS check is performed for jfs only and only one for
    # one device.
    #
    # @param [String] mount_type "jfs", "ext2" or "reiser"
    # @param [String] device, such as /dev/hda3 or /dev/sda8
    # @param [string &] error_message (a reference to string)
    # @return [Boolean] if successfull or if user forces it
    def RunFSCKonJFS(mount_type, device, error_message)
      # #176292, run fsck before jfs is mounted
      if mount_type == "jfs" && device != ""
        if Builtins.contains(@already_checked_jfs_partitions, device)
          Builtins.y2milestone("Device %1 has been already checked...", device)
          return true
        end

        UI.OpenDialog(
          Label(Builtins.sformat(_("Checking file system on %1..."), device))
        )

        Builtins.y2milestone("Running fsck on %1", device)
        # -n == Check read only, make no changes to the file system.
        cmd = Convert.to_map(
          SCR.Execute(
            path(".target.bash_output"),
            Builtins.sformat("fsck.jfs -n %1", device)
          )
        )

        UI.CloseDialog

        # failed
        if Ops.get(cmd, "exit") != 0
          Builtins.y2error("Result: %1", cmd)
          error_message.value = Builtins.tostring(Ops.get(cmd, "stderr"))

          details = ""
          if Ops.get_string(cmd, "stdout", "") != ""
            details = Ops.add(details, Ops.get_string(cmd, "stdout", ""))
          end
          if Ops.get_string(cmd, "stderr", "") != ""
            details = Ops.add(
              Ops.add(details == "" ? "" : "\n", details),
              Ops.get_string(cmd, "stderr", "")
            )
          end

          return AnyQuestionAnyButtonsDetails(
            # popup headline
            _("File System Check Failed"),
            Builtins.sformat(
              # popup question (continue/cancel dialog)
              # %1 is a device name such as /dev/hda5
              _(
                "The file system check of device %1 has failed.\n" +
                  "\n" +
                  "Do you want to continue mounting the device?\n"
              ),
              device
            ),
            Label.ContinueButton,
            # button
            _("&Skip Mounting"),
            details
          ) 
          # succeeded
        else
          # add device into the list of already checked partitions (with exit status 0);
          @already_checked_jfs_partitions = Builtins.add(
            @already_checked_jfs_partitions,
            device
          )
          Builtins.y2milestone("Result: %1", cmd)
          return true
        end
      end

      true
    end


    # Mount partition on specified mount point
    # @param [String] mount_point string mount point to monut the partition at
    # @param [String] device string device to mount
    # @param [String] mount_type string filesystem type to be specified while mounting
    # @return [String] nil on success, error description on fail
    def MountPartition(mount_point, device, mount_type)
      if mount_type == ""
        # e.g. -> "reiserfs"
        mount_type = FileSystems.GetMountString(Storage.DetectFs(device), "")
      end

      # #223878, do not call modprobe with empty mount_type
      if mount_type == ""
        Builtins.y2warning("Unknown filesystem, skipping modprobe...") 
        # #211916, sysfs, proc are not modular
      elsif !Builtins.contains(@non_modular_fs, mount_type)
        # #167976, was broken with "-t ", modprobe before adding it
        Builtins.y2milestone("Calling 'modprobe %1'", mount_type)
        SCR.Execute(path(".target.modprobe"), mount_type, "")
      else
        Builtins.y2milestone(
          "FS type %1 is not modular, skipping modprobe...",
          mount_type
        )
      end

      error_message = nil
      if !(
          error_message_ref = arg_ref(error_message);
          _RunFSCKonJFS_result = RunFSCKonJFS(
            mount_type,
            device,
            error_message_ref
          );
          error_message = error_message_ref.value;
          _RunFSCKonJFS_result
        )
        return error_message
      end

      mount_type = Ops.add("-t ", mount_type) if mount_type != ""

      ret = Convert.to_boolean(
        SCR.Execute(
          path(".target.mount"),
          [
            device,
            Ops.add(Installation.destdir, mount_point),
            Installation.mountlog
          ],
          mount_type
        )
      )
      if ret
        return nil
      else
        return Convert.to_string(
          SCR.Read(path(".target.string"), Installation.mountlog)
        )
      end
    end




    # Check filesystem on a partition and mount the partition on specified mount
    #  point
    # @param [String] mount_point string mount point to monut the partition at
    # @param [String] device string device to mount
    # @param [String] mount_type string filesystem type to be specified while mounting
    # @return [String] nil on success, error description on fail
    def FsckAndMount(mount_point, device, mount_type)
      FSCKPartition(device)

      ret = MountPartition(mount_point, device, mount_type)

      if ret == nil
        AddMountedPartition(
          { :type => "mount", :device => device, :mntpt => mount_point }
        )
      end

      Builtins.y2milestone(
        "mounting (%1, %2, %3) yield %4",
        Ops.add(Installation.destdir, mount_point),
        device,
        mount_type,
        ret
      )

      ret
    end



    #  Check that the root filesystem in fstab has the correct device.
    def check_root_device(partition, fstab, found_partition)
      fstab = deep_copy(fstab)
      tmp = Builtins.filter(fstab) do |entry|
        Ops.get_string(entry, "file", "") == "/"
      end

      if Builtins.size(tmp) != 1
        Builtins.y2error("not exactly one root partition found in fstab")
        found_partition.value = "none"
        return false
      end

      root = Ops.get(tmp, 0, {})

      if !Storage.DeviceRealDisk(Ops.get_string(root, "spec", ""))
        # There's nothing I can check.  Anyway, it's not mounted per device
        # name so it can't be wrong, in theory.
        return true
      end

      true
    end

    # Find a mount point in fstab
    # @param [list <map> &] fstab a list of fstab entries
    # @param [String] mountpoint string a mount point to find
    # @return [String] the found partition
    def FindPartitionInFstab(fstab, mountpoint)
      if Builtins.substring(
          mountpoint,
          Ops.subtract(Builtins.size(mountpoint), 1),
          1
        ) == "/"
        mountpoint = Builtins.substring(
          mountpoint,
          0,
          Ops.subtract(Builtins.size(mountpoint), 1)
        )
      end

      tmp = Builtins.filter(fstab.value) do |entry|
        Ops.get_string(entry, "file", "") == mountpoint ||
          Ops.get_string(entry, "file", "") == Ops.add(mountpoint, "/")
      end

      return nil if Builtins.size(tmp) == 0

      Ops.get_string(tmp, [0, "spec"], "")
    end

    def update_mount_options(options)
      if Builtins.regexpmatch(options, "^(.*,)?hotplug(,.*)?$")
        return Builtins.regexpsub(
          options,
          "^(.*,)?hotplug(,.*)?$",
          "\\1nofail\\2"
        )
      end
      options
    end

    # Translates FS or Cryptotab (old devices to new ones).
    # Such as /dev/hda5 to /dev/sda5.
    #
    # @param list <map> of definitions to translate
    # @param string key name in map to translate
    # @param string key name in map to keep the old value
    # @return [Array<Hash>] of translated definitions
    #
    # @see #https://bugzilla.novell.com/show_bug.cgi?id=258222
    def TranslateFsOrCryptoTab(translate, key_to_translate, key_preserve_as)
      translate = deep_copy(translate)
      # Check whether there is any hardware information that could be used
      check_command = Builtins.sformat(
        "/usr/bin/find '%1/var/lib/hardware/'",
        String.Quote(Installation.destdir)
      )
      cmd = Convert.to_map(
        SCR.Execute(path(".target.bash_output"), check_command)
      )

      if Ops.get(cmd, "exit") != nil
        files = Builtins.splitstring(Ops.get_string(cmd, "stdout", ""), "\n")
        files_count = Builtins.size(files)
        if files_count == nil || Ops.less_or_equal(files_count, 2)
          Builtins.y2error(
            "There are only %1 files in /var/lib/hardware/, translation needn't work!",
            files_count
          )
        else
          Builtins.y2milestone(
            "There are %1 files in /var/lib/hardware/",
            files_count
          )
        end
      end

      # first find a list of values for translation
      old_names = []
      Builtins.foreach(translate) do |m|
        old_names = Builtins.add(
          old_names,
          Ops.get_string(m, key_to_translate, "")
        )
      end

      # translate them
      new_names = Storage.GetTranslatedDevices(
        Installation.installedVersion,
        Installation.updateVersion,
        old_names
      )

      i = 0

      # replace old values with translated ones
      while Ops.less_than(i, Builtins.size(translate))
        default_val = Ops.get_string(translate, [i, key_to_translate], "")
        new_val = Ops.get(new_names, i, default_val)

        Ops.set(translate, [i, key_to_translate], new_val)
        Ops.set(translate, [i, key_preserve_as], default_val)
        Ops.set(@backward_translation, new_val, default_val)

        Ops.set(
          translate,
          [i, "mntops"],
          update_mount_options(Ops.get_string(translate, [i, "mntops"], ""))
        )

        i = Ops.add(i, 1)
      end

      Builtins.y2milestone(
        "Current backward translations: %1",
        @backward_translation
      )

      deep_copy(translate)
    end

    # Register a new fstab agent and read the configuration
    # from Installation::destdir
    def readFsTab(fstab)
      fstab_file = Ops.add(Installation.destdir, "/etc/fstab")

      if FileUtils.Exists(fstab_file)
        SCR.RegisterAgent(
          path(".target.etc.fstab"),
          term(
            :ag_anyagent,
            term(
              :Description,
              term(:File, fstab_file),
              "#\n", # Comment
              false, # read-only
              term(
                :List,
                term(
                  :Tuple,
                  term(:spec, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:file, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:vfstype, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:mntops, term(:String, "^ \t\n")),
                  term(:Optional, term(:Whitespace)),
                  term(:Optional, term(:freq, term(:Number))),
                  term(:Optional, term(:Whitespace)),
                  term(:Optional, term(:passno, term(:Number))),
                  term(:Optional, term(:Whitespace)),
                  term(:Optional, term(:the_rest, term(:String, "^\n")))
                ),
                "\n"
              )
            )
          )
        )

        fstab.value = Convert.convert(
          SCR.Read(path(".target.etc.fstab")),
          :from => "any",
          :to   => "list <map>"
        )

        SCR.UnregisterAgent(path(".target.etc.fstab"))
      else
        Builtins.y2error("No such file %1. Not using fstab.", fstab_file)
      end

      nil
    end

    # Register a new cryptotab agent and read the configuration
    # from Installation::destdir
    def readCryptoTab(crtab)
      crtab_file = Ops.add(Installation.destdir, "/etc/cryptotab")

      if FileUtils.Exists(crtab_file)
        SCR.RegisterAgent(
          path(".target.etc.cryptotab"),
          term(
            :ag_anyagent,
            term(
              :Description,
              term(:File, crtab_file),
              "#\n", # Comment
              false, # read-only
              term(
                :List,
                term(
                  :Tuple,
                  term(:loop, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:file, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:mount, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:vfstype, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:opt1, term(:String, "^\t ")),
                  term(:Separator, "\t "),
                  term(:opt2, term(:String, "^ \t")),
                  term(:Optional, term(:Whitespace)),
                  term(:Optional, term(:the_rest, term(:String, "^\n")))
                ),
                "\n"
              )
            )
          )
        )

        crtab.value = Convert.convert(
          SCR.Read(path(".target.etc.cryptotab")),
          :from => "any",
          :to   => "list <map>"
        )

        SCR.UnregisterAgent(path(".target.etc.cryptotab"))
      else
        Builtins.y2milestone(
          "No such file %1. Not using cryptotab.",
          crtab_file
        )
      end

      nil
    end

    def FstabHasSeparateVar(fstab)
      var_device_fstab = (
        fstab_ref = arg_ref(fstab.value);
        _FindPartitionInFstab_result = FindPartitionInFstab(fstab_ref, "/var");
        fstab.value = fstab_ref.value;
        _FindPartitionInFstab_result
      )
      Builtins.y2milestone("/var partition is %1", var_device_fstab)

      var_device_fstab != nil
    end


    def FstabUsesKernelDeviceNameForHarddisks(fstab)
      fstab = deep_copy(fstab)
      # We just want to check the use of kernel device names for hard
      # disks. Not for e.g. BIOS RAIDs or LVM logical volumes.

      # Since we are looking at device names of hard disks that may no
      # longer exist all we have at hand is the name.

      Builtins.find(fstab) do |line|
        spec = Ops.get_string(line, "spec", "error")
        next true if Builtins.regexpmatch(spec, "^/dev/sd[a-z]+[0-9]+$")
        next true if Builtins.regexpmatch(spec, "^/dev/hd[a-z]+[0-9]+$")
        next true if Builtins.regexpmatch(spec, "^/dev/dasd[a-z]+[0-9]+$")
        false
      end != nil
    end


    # Reads FSTab and CryptoTab and fills fstab and crtab got as parameters.
    # Uses Installation::destdir as the base mount point.
    #
    # @param list <map> ('pointer' to) fstab
    # @param list <map> ('pointer' to) crtab
    # @param string root device
    def read_fstab_and_cryptotab(fstab, crtab, root_device_current)
      default_scr = WFM.SCRGetDefault
      new_scr = nil
      @backward_translation = {}

      if Stage.initial
        fstab_ref = arg_ref(fstab.value)
        readFsTab(fstab_ref)
        fstab.value = fstab_ref.value
        crtab_ref = arg_ref(crtab.value)
        readCryptoTab(crtab_ref)
        crtab.value = crtab_ref.value
      else
        fstab.value = Convert.convert(
          SCR.Read(path(".etc.fstab")),
          :from => "any",
          :to   => "list <map>"
        )
        crtab.value = Convert.convert(
          SCR.Read(path(".etc.cryptotab")),
          :from => "any",
          :to   => "list <map>"
        )
      end

      fstab_has_separate_var = (
        fstab_ref = arg_ref(fstab.value);
        _FstabHasSeparateVar_result = FstabHasSeparateVar(fstab_ref);
        fstab.value = fstab_ref.value;
        _FstabHasSeparateVar_result
      )
      # mount /var
      if fstab_has_separate_var
        Builtins.y2warning("Separate /var partition!")
        MountVarIfRequired(fstab.value, root_device_current, false)
      else
        Builtins.y2milestone("No separate /var partition found")
      end

      Builtins.y2milestone("fstab: %1", fstab.value)
      fstab.value = TranslateFsOrCryptoTab(fstab.value, "spec", "spec_old")
      Builtins.y2milestone("fstab: (translated) %1", fstab.value)

      Builtins.y2milestone("crtab: %1", crtab.value)
      crtab.value = TranslateFsOrCryptoTab(crtab.value, "file", "file_old")
      Builtins.y2milestone("crtab: (translated) %1", crtab.value)

      # umount /var
      if fstab_has_separate_var
        SCR.Execute(
          path(".target.umount"),
          Ops.add(Installation.destdir, "/var")
        )
        @activated = Builtins.remove(@activated, 0)
      end

      true
    end


    #
    def PrepareCryptoTab(crtab, fstab)
      crtab = deep_copy(crtab)
      crypt_nb = 0

      Builtins.foreach(crtab) do |mounts|
        vfstype = Ops.get_string(mounts, "vfstype", "")
        mntops = Ops.get_string(mounts, "opt2", "")
        loop = Ops.get_string(mounts, "loop", "")
        fspath = Ops.get_string(mounts, "mount", "")
        device = Ops.get_string(mounts, "file", "")
        Builtins.y2milestone(
          "vfstype:%1 mntops:%2 loop:%3 fspath:%4 device:%5",
          vfstype,
          mntops,
          loop,
          fspath,
          device
        )
        if !Builtins.issubstring(mntops, "noauto")
          again = true
          while again
            crypt_ok = true
            crypt_passwd = DlgUpdateCryptFs(device, fspath)

            if crypt_passwd == nil || crypt_passwd == ""
              crypt_ok = false
              again = false
            end

            Builtins.y2milestone("crypt pwd ok:%1", crypt_ok)

            if crypt_ok
              setloop = {
                "encryption"    => "twofish",
                "passwd"        => crypt_passwd,
                "loop_dev"      => loop,
                "partitionName" => device
              }

              crypt_ok = (
                setloop_ref = arg_ref(setloop);
                _PerformLosetup_result = Storage.PerformLosetup(
                  setloop_ref,
                  false
                );
                setloop = setloop_ref.value;
                _PerformLosetup_result
              )
              Builtins.y2milestone("crypt ok: %1", crypt_ok)
              if crypt_ok
                loop = Ops.get_string(setloop, "loop_dev", "")
              else
                # yes-no popup
                again = Popup.YesNo(_("Incorrect password. Try again?"))
              end
            end

            if crypt_ok
              add_fs = {
                "file"    => fspath,
                "mntops"  => mntops,
                "spec"    => loop,
                "freq"    => 0,
                "passno"  => 0,
                "vfstype" => vfstype
              }
              fstab.value = Builtins.prepend(fstab.value, add_fs)
              AddMountedPartition({ :type => "crypt", :device => device })
              again = false
            end
          end
        end
      end

      true
    end


    # Check if specified mount point is mounted
    # @param [String] mountpoint the mount point to be checked
    # @return [Boolean] true if it is mounted
    def IsMounted(mountpoint)
      if Builtins.substring(
          mountpoint,
          Ops.subtract(Builtins.size(mountpoint), 1),
          1
        ) == "/"
        mountpoint = Builtins.substring(
          mountpoint,
          0,
          Ops.subtract(Builtins.size(mountpoint), 1)
        )
      end

      ret = true
      Builtins.foreach(@activated) do |e|
        if Ops.get_string(e, :type, "") == "mount" &&
            (Ops.get_string(e, :mntpt, "") == mountpoint ||
              Ops.get_string(e, :mntpt, "") == Ops.add(mountpoint, "/"))
          ret = true
        end
      end
      ret
    end

    # bugzilla #258563
    def CheckBootSize(bootpart)
      min_suggested_bootsize = 65536
      min_suggested_bootsize = 204800 if Arch.ia64

      bootsize = nil

      cmd = Builtins.sformat(
        "/bin/df --portability --no-sync -k '%1/boot' | grep -v '^Filesystem' | sed 's/[ ]\\+/ /g'",
        Installation.destdir
      )
      bootsizeout = Convert.to_map(
        SCR.Execute(path(".target.bash_output"), cmd)
      )

      if Ops.get_integer(bootsizeout, "exit", -1) != 0
        Builtins.y2error("Error: '%1' -> %2", cmd, bootsizeout)
      else
        scriptout = Builtins.splitstring(
          Ops.get_string(bootsizeout, "stdout", ""),
          " "
        )
        Builtins.y2milestone("Scriptout: %1", scriptout)
        bootsize = Builtins.tointeger(Ops.get(scriptout, 1, "0"))
      end

      if bootsize == nil || bootsize == 0
        Builtins.y2error(
          "Cannot find out bootpart size: %1",
          Installation.destdir
        )
        return true
      end

      Builtins.y2milestone(
        "Boot size is: %1 recommended min.: %2",
        bootsize,
        min_suggested_bootsize
      )

      # Size of the /boot partition is satisfactory
      if Ops.greater_or_equal(bootsize, min_suggested_bootsize)
        return true 

        # Less than a hero
      else
        current_bs = Ops.divide(bootsize, 1024)
        suggested_bs = Ops.divide(min_suggested_bootsize, 1024)

        cont = Popup.ContinueCancelHeadline(
          # TRANSLATORS: a popup headline
          _("Warning"),
          # TRANSLATORS: error message,
          # %1 is replaced with the current /boot partition size
          # %2 with the recommended size
          Builtins.sformat(
            _(
              "Your /boot partition is too small (%1 MB).\n" +
                "We recommend a size of no less than %2 MB or else the new Kernel may not fit.\n" +
                "It is safer to either enlarge the partition\n" +
                "or not use a /boot partition at all.\n" +
                "\n" +
                "Do you want to continue updating the current system?\n"
            ),
            current_bs,
            suggested_bs
          )
        )

        if cont
          Builtins.y2warning(
            "User decided to continue despite small a /boot partition"
          )
          return true
        else
          Builtins.y2milestone(
            "User decided not to continue with small /boot partition"
          )
          return false
        end
      end
    end

    #
    def MountFSTab(fstab, message)
      fstab = deep_copy(fstab)
      allowed_fs = [
        "ext",
        "ext2",
        "ext3",
        "ext4",
        "btrfs",
        "minix",
        "reiserfs",
        "jfs",
        "xfs",
        "xiafs",
        "hpfs",
        "vfat",
        "auto",
        "proc"
      ]

      # mount sysfs first
      ret = MountPartition("/sys", "sysfs", "sysfs")

      if ret == nil
        AddMountedPartition(
          { :type => "mount", :device => "sysfs", :mntpt => "/sys" }
        )
      end


      success = true

      raidMounted = false

      Builtins.foreach(fstab) do |mounts|
        vfstype = Ops.get_string(mounts, "vfstype", "")
        mntops = Ops.get_string(mounts, "mntops", "")
        spec = Ops.get_string(mounts, "spec", "")
        fspath = Ops.get_string(mounts, "file", "")
        if Builtins.contains(allowed_fs, vfstype) && fspath != "/" &&
            (fspath != "/var" || !IsMounted("/var")) &&
            !Builtins.issubstring(mntops, "noauto")
          Builtins.y2milestone("mounting %1 to %2", spec, fspath)

          if !Mode.test
            mount_type = ""
            mount_type = vfstype if vfstype == "proc"

            mount_err = ""
            while mount_err != nil
              mount_err = FsckAndMount(fspath, spec, mount_type)
              if mount_err != nil
                Builtins.y2error(
                  "mounting %1 (type %2) on %3 failed",
                  spec,
                  mount_type,
                  Ops.add(Installation.destdir, fspath)
                )
                UI.OpenDialog(
                  VBox(
                    Label(
                      Builtins.sformat(
                        # label in a popup, %1 is device (eg. /dev/hda1), %2 is output of the 'mount' command
                        _(
                          "The partition %1 could not be mounted.\n" +
                            "\n" +
                            "%2\n" +
                            "\n" +
                            "If you are sure that the partition is not necessary for the\n" +
                            "update (not a system partition), click Continue.\n" +
                            "To check or fix the mount options, click Specify Mount Options.\n" +
                            "To abort the update, click Cancel.\n"
                        ),
                        spec,
                        mount_err
                      )
                    ),
                    VSpacing(1),
                    HBox(
                      PushButton(Id(:cont), Label.ContinueButton),
                      # push button
                      PushButton(Id(:cmd), _("&Specify Mount Options")),
                      PushButton(Id(:cancel), Label.CancelButton)
                    )
                  )
                )
                act = Convert.to_symbol(UI.UserInput)
                UI.CloseDialog
                if act == :cancel
                  mount_err = nil
                  success = false
                elsif act == :cont
                  mount_err = nil
                elsif act == :cmd
                  UI.OpenDialog(
                    VBox(
                      # popup heading
                      Heading(_("Mount Options")),
                      VSpacing(0.6),
                      # text entry label
                      TextEntry(Id(:mp), _("&Mount Point"), fspath),
                      VSpacing(0.4),
                      # tex entry label
                      TextEntry(Id(:device), _("&Device"), spec),
                      VSpacing(0.4),
                      # text entry label
                      TextEntry(
                        Id(:fs),
                        _("&File System\n(empty for autodetection)"),
                        mount_type
                      ),
                      VSpacing(1),
                      HBox(
                        PushButton(Id(:ok), Label.OKButton),
                        PushButton(Id(:cancel), Label.CancelButton)
                      )
                    )
                  )
                  act = Convert.to_symbol(UI.UserInput)
                  if act == :ok
                    fspath = Convert.to_string(UI.QueryWidget(Id(:mp), :Value))
                    spec = Convert.to_string(
                      UI.QueryWidget(Id(:device), :Value)
                    )
                    mount_type = Convert.to_string(
                      UI.QueryWidget(Id(:fs), :Value)
                    )
                  end
                  UI.CloseDialog
                end
              end
            end

            if fspath == "/boot" || fspath == "/boot/"
              checkspec = spec

              # translates new device name to the old one because
              # storage still returns them in the old way
              if Ops.get(@backward_translation, spec) != nil
                checkspec = Ops.get(@backward_translation, spec, spec)
              end

              success = false if !CheckBootSize(checkspec)
            end
          end # allowed_fs
        elsif vfstype == "swap" && fspath == "swap"
          Builtins.y2milestone("mounting %1 to %2", spec, fspath)

          if !Mode.test
            command = "/sbin/swapon "
            if spec != ""
              # swap-partition
              command = Ops.add(command, spec)

              # run /sbin/swapon
              ret_from_shell = Convert.to_integer(
                SCR.Execute(path(".target.bash"), command)
              )
              if ret_from_shell != 0
                Builtins.y2error("swapon failed: %1", command)
              else
                AddMountedPartition({ :type => "swap", :device => spec })
              end
            end
          end
        end
      end

      success
    end

    # Mount /var partition
    # @param [String] device string device holding the /var subtree
    # @return [String] nil on success, error description on fail
    def MountVarPartition(device)
      mount_err = FsckAndMount("/var", device, "")
      err_message = nil
      if mount_err != nil
        Builtins.y2error(-1, "failed to mount /var")
        err_message = Ops.add(
          Ops.add(
            Ops.add(
              Ops.add(
                Builtins.sformat(
                  # error message
                  _("The /var partition %1 could not be mounted.\n"),
                  device
                ),
                "\n"
              ),
              mount_err
            ),
            "\n\n"
          ),
          @sdb
        )
      end
      err_message
    end

    # <-- BNC #448577, Cannot find /var partition automatically
    # returns if successful
    def MountUserDefinedVarPartition
      # function return value
      manual_mount_successful = false

      list_of_devices = []
      # $[ "/dev/sda3" : "Label: My_Partition" ]
      device_info = {}

      # Creating the list of known partitions
      Builtins.foreach(Storage.GetOndiskTarget) do |device, description|
        Builtins.foreach(Ops.get_list(description, "partitions", [])) do |partition|
          # Some partitions logically can't be used for /var
          next if Ops.get_symbol(partition, "detected_fs", :unknown) == :swap
          next if Ops.get_symbol(partition, "type", :unknown) == :extended
          next if !Builtins.haskey(partition, "device")
          list_of_devices = Builtins.add(
            list_of_devices,
            Ops.get_string(partition, "device", "")
          )
          Ops.set(
            device_info,
            Ops.get_string(partition, "device", ""),
            Builtins.sformat(
              # Informational text about selected partition, %x are replaced with values later
              _(
                "<b>File system:</b> %1, <b>Type:</b> %2,<br>\n" +
                  "<b>Label:</b> %3, <b>Size:</b> %4,<br>\n" +
                  "<b>udev IDs:</b> %5,<br>\n" +
                  "<b>udev path:</b> %6"
              ),
              # starts with >`<
              Builtins.substring(
                Builtins.tostring(
                  Ops.get_symbol(partition, "detected_fs", :unknown)
                ),
                1
              ),
              Ops.get_locale(partition, "fstype", _("Unknown")),
              Ops.get_locale(partition, "label", _("None")),
              String.FormatSize(
                Ops.multiply(Ops.get_integer(partition, "size_k", 0), 1024)
              ),
              Builtins.mergestring(Ops.get_list(partition, "udev_id", []), ", "),
              Ops.get_locale(partition, "udev_path", _("Unknown"))
            )
          )
        end
      end

      list_of_devices = Builtins.sort(list_of_devices)
      Builtins.y2milestone("Known devices: %1", list_of_devices)

      while true
        UI.OpenDialog(
          VBox(
            MarginBox(
              1,
              0,
              VBox(
                # a popup caption
                Left(
                  Heading(_("Unable to find the /var partition automatically"))
                ),
                # a popup message
                Left(
                  Label(
                    _(
                      "Your system uses a separate /var partition which is required for the upgrade\n" +
                        "process to detect the disk-naming changes. Select the /var partition manually\n" +
                        "to continue the upgrade process."
                    )
                  )
                ),
                VSpacing(1),
                Left(
                  ComboBox(
                    Id("var_device"),
                    Opt(:notify),
                    # a combo-box label
                    _("&Select /var Partition Device"),
                    list_of_devices
                  )
                ),
                VSpacing(0.5),
                # an informational rich-text widget label
                Left(Label(_("Device Info"))),
                MinHeight(3, RichText(Id("device_info"), "")),
                VSpacing(1)
              )
            ),
            MarginBox(
              1,
              0,
              ButtonBox(
                PushButton(Id(:ok), Opt(:okButton), Label.OKButton),
                PushButton(Id(:cancel), Opt(:cancelButton), Label.CancelButton)
              )
            )
          )
        )

        ret = nil

        # initial device
        var_device = Convert.to_string(UI.QueryWidget(Id("var_device"), :Value))
        UI.ChangeWidget(
          Id("device_info"),
          :Value,
          Ops.get(device_info, var_device, "")
        )

        # to handle switching the combo-box or [OK]/[Cancel]
        while true
          ret = UI.UserInput
          var_device = Convert.to_string(
            UI.QueryWidget(Id("var_device"), :Value)
          )

          if ret == "var_device"
            UI.ChangeWidget(
              Id("device_info"),
              :Value,
              Ops.get(device_info, var_device, "")
            )
          else
            break
          end
        end

        UI.CloseDialog

        # Trying user-selection
        if ret == :ok
          Builtins.y2milestone("Trying to mount %1 as /var", var_device)
          mount_error = MountVarPartition(var_device)

          if mount_error != nil
            Report.Error(mount_error)
            next
          else
            Builtins.y2milestone("Manual mount (/var) successful")
            manual_mount_successful = true
            break
          end 
          # `cancel
        else
          Builtins.y2warning(
            "User doesn't want to enter the /var partition device"
          )
          break
        end
      end

      manual_mount_successful
    end
    def MountVarIfRequired(fstab, root_device_current, manual_var_mount)
      fstab = deep_copy(fstab)
      var_device_fstab = (
        fstab_ref = arg_ref(fstab);
        _FindPartitionInFstab_result = FindPartitionInFstab(fstab_ref, "/var");
        fstab = fstab_ref.value;
        _FindPartitionInFstab_result
      )

      # No need to mount "/var", it's not separate == already mounted with "/"
      if var_device_fstab == nil
        Builtins.y2milestone("Not a separate /var...")
        return nil
      end

      if !Storage.DeviceRealDisk(var_device_fstab)
        Builtins.y2milestone(
          "Device %1 is not a real disk, mounting...",
          var_device_fstab
        )
        return MountVarPartition(var_device_fstab)
      end

      # BNC #494240: If a device name is not created by Kernel, we can use it for upgrade
      if !Storage.IsKernelDeviceName(var_device_fstab)
        Builtins.y2milestone(
          "Device %1 is not a Kernel device name, mounting...",
          var_device_fstab
        )
        return MountVarPartition(var_device_fstab)
      end

      tmp1 = Builtins.filter(fstab) do |entry|
        Ops.get_string(entry, "file", "") == "/"
      end
      root_device_fstab = Ops.get_string(tmp1, [0, "spec"], "")
      if !Storage.DeviceRealDisk(root_device_fstab)
        return MountVarPartition(var_device_fstab)
      end

      root_info = Storage.GetDiskPartition(root_device_fstab)
      var_info = Storage.GetDiskPartition(var_device_fstab)

      if Ops.get_string(root_info, "disk", "") ==
          Ops.get_string(var_info, "disk", "")
        tmp2 = Storage.GetDiskPartition(root_device_current)
        var_partition_current2 = Storage.GetDeviceName(
          Ops.get_string(tmp2, "disk", ""),
          Ops.get_integer(var_info, "nr", 0)
        )

        return MountVarPartition(var_partition_current2)
      end

      realdisks = []
      Builtins.foreach(Storage.GetOndiskTarget) do |s, m|
        # BNC #448577, checking device
        if Storage.IsKernelDeviceName(s) && Storage.DeviceRealDisk(s)
          realdisks = Builtins.add(realdisks, s)
        end
      end

      if Builtins.size(realdisks) != 2
        # <-- BNC #448577, Cannot find /var partition automatically
        return nil if manual_var_mount && MountUserDefinedVarPartition()

        Builtins.y2error(
          "don't know how to handle more than two disks at this point"
        )
        # error message
        return Ops.add(
          _("Unable to mount /var partition with this disk configuration.\n"),
          @sdb
        )
      end

      other_disk = Ops.get(
        realdisks,
        Ops.get(realdisks, 0, "") == Ops.get_string(root_info, "disk", "") ? 1 : 0,
        ""
      )
      var_partition_current = Storage.GetDeviceName(
        other_disk,
        Ops.get_integer(var_info, "nr", 0)
      )

      MountVarPartition(var_partition_current)
    end


    # Mounting root-partition; reading fstab and mounting read partitions
    def MountPartitions(root_device_current)
      Builtins.y2milestone("mount partitions: %1", root_device_current)

      return true if @did_try_mount_partitions

      @did_try_mount_partitions = true

      success = true

      # popup message, %1 will be replace with the name of the logfile
      message = Builtins.sformat(
        _(
          "Partitions could not be mounted.\n" +
            "\n" +
            "Check the log file %1."
        ),
        Ops.add(Directory.logdir, "/y2log")
      )
      Builtins.y2milestone("selected partition: %1", root_device_current)

      ret_bool = true

      fstab = []
      crtab = []

      # Mount selected root partition to Installation::destdir
      ret_bool = nil == FsckAndMount("/", root_device_current, "") if !Mode.test

      if ret_bool
        # read the keyboard settings now, so that it used when
        # typing passwords for encrypted partitions
        # Calling a script because otherwise this module would depend on yast2-country
        if Stage.initial
          WFM.call(
            "rootpart_check_keyboard",
            [{ "destdir" => Installation.destdir }]
          )
        end

        fstab_ref = arg_ref(fstab)
        crtab_ref = arg_ref(crtab)
        read_fstab_and_cryptotab(fstab_ref, crtab_ref, root_device_current)
        fstab = fstab_ref.value
        crtab = crtab_ref.value
        Storage.ChangeDmNamesFromCrypttab(
          Ops.add(Installation.destdir, "/etc/crypttab")
        )
        Update.GetProductName

        if FstabUsesKernelDeviceNameForHarddisks(fstab)
          Builtins.y2warning(
            "fstab on %1 uses kernel device name for hard disks",
            root_device_current
          )
          warning = Builtins.sformat(
            _(
              "Some partitions in the system on %1 are mounted by kernel-device name. This is\n" +
                "not reliable for the update since kernel-device names are unfortunately not\n" +
                "persistent. It is strongly recommended to start the old system and change the\n" +
                "mount-by method to any other method for all partitions."
            ),
            root_device_current
          )
          if Mode.autoupgrade
            Popup.TimedWarning(warning, 10)
          else
            Popup.Warning(warning)
          end
        end

        if Builtins.size(fstab) == 0
          Builtins.y2error("no or empty fstab found!")
          # error message
          message = _("No fstab found.")
          success = false
        else
          tmp_msg = MountVarIfRequired(fstab, root_device_current, true)
          if tmp_msg != nil
            Builtins.y2error("failed to mount /var!")
            message = tmp_msg
            success = false
          else
            tmp = ""

            if !(
                tmp_ref = arg_ref(tmp);
                check_root_device_result = check_root_device(
                  root_device_current,
                  fstab,
                  tmp_ref
                );
                tmp = tmp_ref.value;
                check_root_device_result
              )
              Builtins.y2error("fstab has wrong root device!")
              # message part 1
              message = Ops.add(
                Ops.add(
                  _(
                    "The root partition in /etc/fstab has an invalid root device.\n"
                  ),
                  # message part 2
                  Builtins.sformat(
                    _("It is currently mounted as %1 but listed as %2.\n"),
                    root_device_current,
                    tmp
                  )
                ),
                @sdb
              )
              success = false
            else
              Builtins.y2milestone("cryptotab %1", crtab)

              fstab_ref = arg_ref(fstab)
              PrepareCryptoTab(crtab, fstab_ref)
              fstab = fstab_ref.value

              Builtins.y2milestone("fstab %1", fstab)

              if !(
                  message_ref = arg_ref(message);
                  _MountFSTab_result = MountFSTab(fstab, message_ref);
                  message = message_ref.value;
                  _MountFSTab_result
                )
                success = false
              end
            end
          end
        end
      else
        Builtins.y2error(
          "Could not mount root '%1' to '%2'",
          root_device_current,
          Installation.destdir
        )
        success = false
      end

      Builtins.y2milestone(
        "MountPartition (%1) = %2",
        root_device_current,
        success
      )
      Builtins.y2milestone("activated %1", @activated)

      if !success
        Popup.Message(message)

        # some mount failed, unmount all mounted fs
        UnmountPartitions(false)
        @did_try_mount_partitions = true
      else
        # enter the mount points of the newly mounted partitions
        # in the target map of the storage module
        AddToTargetMap()
      end

      success
    end

    # Get architecture of an elf file.
    def GetArchOfELF(filename)
      bash_out = Convert.to_map(
        SCR.Execute(
          path(".target.bash_output"),
          Ops.add(Ops.add(Directory.ybindir, "/elf-arch "), filename)
        )
      )
      return "unknown" if Ops.get_integer(bash_out, "exit", 1) != 0
      Builtins.deletechars(Ops.get_string(bash_out, "stdout", "unknown"), "\n")
    end

    # Checks the partition whether it contains an incomplete installation.
    #
    # @see BNC #441919
    # @param string system mounted to directory
    # @return [Boolean] true if incomplete
    def IncompleteInstallationDetected(mounted_to)
      # by default, installation is complete
      ret = false

      Builtins.foreach([Installation.run_yast_at_boot]) do |check_this|
        check_this = Builtins.sformat("%1/%2", mounted_to, check_this)
        if FileUtils.Exists(check_this) == true
          Builtins.y2milestone(
            "File %1 exists, installation is incomplete",
            check_this
          )
          ret = true
          raise Break
        end
      end

      ret
    end

    # Check a root partition and return map with infomations (see
    # variable rootPartitions).
    def CheckPartition(partition)
      partition = deep_copy(partition)
      freshman = {
        :valid  => false,
        :name   => "unknown",
        :arch   => "unknown",
        :label  => Ops.get_string(partition, "label", ""),
        :fs     => Ops.get_symbol(partition, "detected_fs", :unknown),
        :fstype => Ops.get_string(partition, "fstype", "unknown")
      }

      p_dev = Ops.get_string(partition, "device", "error")
      p_fsid = Ops.get_integer(partition, "fsid", 0)
      p_type = Ops.get_symbol(partition, "type", :primary)
      p_detect_fs = Ops.get_symbol(partition, "detected_fs", :unknown)

      # possible root FS
      if Builtins.contains(FileSystems.possible_root_fs, p_detect_fs)
        mt_map = {
          :ext2   => "ext2",
          :ext3   => "ext3",
          :ext4   => "ext4",
          :btrfs  => "btrfs",
          :reiser => "reiserfs",
          :xfs    => "xfs",
          :jfs    => "jfs"
        }
        mount_type = Ops.get(mt_map, p_detect_fs, "")

        error_message = nil
        if !(
            error_message_ref = arg_ref(error_message);
            _RunFSCKonJFS_result = RunFSCKonJFS(
              mount_type,
              p_dev,
              error_message_ref
            );
            error_message = error_message_ref.value;
            _RunFSCKonJFS_result
          )
          Ops.set(freshman, :valid, false)
          return deep_copy(freshman)
        end

        # mustn't be empty and must be modular
        if mount_type != "" && !Builtins.contains(@non_modular_fs, mount_type)
          SCR.Execute(path(".target.modprobe"), mount_type, "")
        end
        # mount (read-only) partition to Installation::destdir
        Storage.RemoveDmMapsTo(p_dev)
        if Convert.to_boolean(
            SCR.Execute(
              path(".target.mount"),
              [p_dev, Installation.destdir, Installation.mountlog],
              "-o ro"
            )
          )
          # Is this a root partition, does /etc/fstab exists?
          if Ops.greater_than(
              SCR.Read(
                path(".target.size"),
                Ops.add(Installation.destdir, "/etc/fstab")
              ),
              0
            )
            Builtins.y2milestone("found fstab on %1", partition)

            fstab = []
            crtab = []

            fstab_ref = arg_ref(fstab)
            crtab_ref = arg_ref(crtab)
            read_fstab_and_cryptotab(fstab_ref, crtab_ref, p_dev)
            fstab = fstab_ref.value
            crtab = crtab_ref.value
            Update.GetProductName

            fstab = Builtins.filter(fstab) do |p|
              Ops.get_string(p, "file", "") == "/"
            end

            if Builtins.size(Ops.get_string(fstab, [0, "spec"], "")) == 0
              Builtins.y2warning("Cannot find / entry in fstab %1", fstab)
            end

            Ops.set(
              freshman,
              :valid,
              Ops.greater_than(
                Builtins.size(Ops.get_string(fstab, [0, "spec"], "")),
                0
              ) &&
                Storage.DeviceMatchFstab(
                  p_dev,
                  Ops.get_string(
                    # bugzilla #304269
                    # DeviceMatchFstab expects _old_ not _translated_ device
                    fstab,
                    [0, "spec_old"],
                    Ops.get_string(fstab, [0, "spec"], "")
                  )
                )
            )

            # Why this doesn't match?
            # Possible reasons:
            # - /var not mounted so hwinfo cannot translate device names
            if Ops.get_boolean(freshman, :valid, false) != true
              Builtins.y2warning(
                "Device does not match fstab: '%1' vs. '%2'",
                p_dev,
                Ops.get_string(fstab, [0, "spec"], "")
              )
            end
            if Mode.autoinst
              # we dont care about the other checks in autoinstallation
              SCR.Execute(path(".target.umount"), Installation.destdir)
              return deep_copy(freshman)
            end

            # Get installed release name
            release = OSRelease.ReleaseInformation(Installation.destdir)
            Builtins.y2debug("release: %1", release)
            if release == "?"
              # label for an unknown installed system
              release = _("Unknown")
            end
            Ops.set(freshman, :name, release)

            # Right architecture?
            Ops.set(
              freshman,
              :arch,
              GetArchOfELF(Ops.add(Installation.destdir, "/bin/bash"))
            )
            instsys_arch = GetArchOfELF("/bin/bash")

            # `arch_valid, see bugzilla #288201
            # installed /bin/bash and the one from inst-sys are matching
            if Ops.get_string(freshman, :arch, "unknown") == instsys_arch
              Builtins.y2milestone("Architecture (%1) is valid", instsys_arch)
              Ops.set(freshman, :arch_valid, true) 

              # both are PPC, bugzilla #249791
            elsif Builtins.contains(
                ["ppc", "ppc64"],
                Ops.get_string(freshman, :arch, "unknown")
              ) &&
                Builtins.contains(["ppc", "ppc64"], instsys_arch)
              Builtins.y2milestone(
                "Architecture for partition %1 is %2, upgrading %3",
                p_dev,
                Ops.get_string(freshman, :arch, "unknown"),
                instsys_arch
              )
              Ops.set(freshman, :arch_valid, true) 

              # Architecture is not matching
            else
              Builtins.y2milestone(
                "Architecture for partition %1 is %2, upgrading %3",
                p_dev,
                Ops.get_string(freshman, :arch, "unknown"),
                instsys_arch
              )
              Ops.set(freshman, :arch_valid, false)
            end

            # If architecture is not matching, the whole partition is considered to be wrong
            if Ops.get_boolean(freshman, :arch_valid, false) != true
              Builtins.y2milestone(
                "Architecture is not valid -> the whole partition is not valid"
              )
              Ops.set(freshman, :valid, false)
            end

            if IncompleteInstallationDetected(Installation.destdir)
              Builtins.y2milestone(
                "Incomplete installation detected, partition is not valid"
              )
              Ops.set(freshman, :valid, false)
            end

            Builtins.y2milestone(
              "Partition is valid: %1, arch is valid: %2",
              Ops.get_boolean(freshman, :valid, false),
              Ops.get_boolean(freshman, :arch_valid, false)
            )
          end

          # unmount partition
          SCR.Execute(path(".target.umount"), Installation.destdir)
        end
      end

      Builtins.y2milestone("%1 %2", partition, freshman)

      deep_copy(freshman)
    end


    # Find all valid root partitions and place the result in rootPartitions.
    # The partitions are mounted and unmounted again (to Installation::destdir).
    # Loads a bunch of kernel modules.
    # @return [void]
    def FindRootPartitions
      return if @didSearchForRootPartitions

      ModuleLoading.Load(
        "reiserfs",
        "",
        "Linux",
        "Reiser FS",
        Linuxrc.manual,
        true
      )
      ModuleLoading.Load("jfs", "", "Linux", "JFS", Linuxrc.manual, true)
      ModuleLoading.Load("xfs", "", "Linux", "XFS", Linuxrc.manual, true)
      ModuleLoading.Load("ext3", "", "Linux", "Ext3", Linuxrc.manual, true)
      ModuleLoading.Load("ext4", "", "Linux", "Ext4", Linuxrc.manual, true)
      ModuleLoading.Load("btrfs", "", "Linux", "BtrFS", Linuxrc.manual, true)
      ModuleLoading.Load("raid0", "", "Linux", "Raid 0", Linuxrc.manual, true)
      ModuleLoading.Load("raid1", "", "Linux", "Raid 1", Linuxrc.manual, true)
      ModuleLoading.Load("raid5", "", "Linux", "Raid 5", Linuxrc.manual, true)
      ModuleLoading.Load("raid6", "", "Linux", "Raid 6", Linuxrc.manual, true)
      ModuleLoading.Load("raid10", "", "Linux", "Raid 10", Linuxrc.manual, true)
      ModuleLoading.Load(
        "multipath",
        "",
        "Linux",
        "Multipath",
        Linuxrc.manual,
        true
      )
      ModuleLoading.Load("dm-mod", "", "Linux", "DM", Linuxrc.manual, true)
      SCR.Execute(path(".target.bash"), "/sbin/devmap_mknod.sh")
      ModuleLoading.Load("dm-snapshot", "", "Linux", "DM", Linuxrc.manual, true)

      if Mode.test
        Storage.SetTargetMap(
          Convert.convert(
            SCR.Read(path(".target.yast2"), "test_target_map.ycp"),
            :from => "any",
            :to   => "map <string, map>"
          )
        )
      end

      #	Storage::ActivateEvms();
      target_map = Storage.GetOndiskTarget
      Builtins.y2milestone("target_map: %1", target_map)

      # prepare progress-bar
      if UI.WidgetExists(Id("search_progress"))
        UI.ReplaceWidget(
          Id("search_progress"),
          ProgressBar(
            Id("search_pb"),
            _("Evaluating root partition. One moment please..."),
            100,
            0
          )
        )
      end

      @rootPartitions = {}
      @numberOfValidRootPartitions = 0

      # all partitions on all devices
      max_steps = 0
      Builtins.foreach(target_map) do |device, description|
        max_steps = Ops.add(
          max_steps,
          Builtins.size(Ops.get_list(description, "partitions", []))
        )
      end

      counter = 0
      Builtins.foreach(target_map) do |device, description|
        Builtins.foreach(Ops.get_list(description, "partitions", [])) do |partition|
          counter = Ops.add(counter, 1)
          if UI.WidgetExists(Id("search_progress"))
            UI.ChangeWidget(
              Id("search_pb"),
              :Value,
              Ops.divide(Ops.multiply(100, counter), max_steps)
            )
          end
          # some partitions don't make sense at all
          if Ops.get_symbol(partition, "detected_fs", :unknown) != :swap &&
              Ops.get_symbol(partition, "type", :primary) != :extended
            freshman = {}

            if Mode.test
              freshman = {
                :valid => true,
                :name  => "SuSE Linux 4.2",
                :arch  => "i286",
                :label => "Label"
              }
            else
              freshman = CheckPartition(partition)
            end

            @rootPartitions = Builtins.add(
              @rootPartitions,
              Ops.get_string(partition, "device", "error"),
              freshman
            )

            if Ops.get_boolean(freshman, :valid, false)
              @numberOfValidRootPartitions = Ops.add(
                @numberOfValidRootPartitions,
                1
              )
            end
          end
        end
      end

      # 100%
      if UI.WidgetExists(Id("search_progress"))
        UI.ChangeWidget(Id("search_pb"), :Value, 100)
      end

      @didSearchForRootPartitions = true

      Builtins.y2milestone("rootPartitions: %1", @rootPartitions)

      nil
    end

    def GetDistroArch
      GetArchOfELF("/bin/bash")
    end

    def mount_target
      UI.OpenDialog(
        Opt(:decorated),
        # intermediate popup while mounting partitions
        Label(_("Mounting partitions. One moment please..."))
      )

      tmp = MountPartitions(@selectedRootPartition)
      # sleep (500);

      UI.CloseDialog

      tmp
    end

    def Detect
      if !@didSearchForRootPartitions
        Wizard.SetContents(
          # TRANSLATORS: dialog caption
          _("Searching for Available Systems"),
          VBox(ReplacePoint(Id("search_progress"), Empty())),
          "",
          false,
          false
        )

        FindRootPartitions()

        @selectedRootPartition = ""
        Builtins.y2milestone("Detected root partitions: %1", @rootPartitions)
      end

      nil
    end

    publish :variable => :selectedRootPartition, :type => "string"
    publish :variable => :previousRootPartition, :type => "string"
    publish :variable => :rootPartitions, :type => "map <string, map>"
    publish :variable => :numberOfValidRootPartitions, :type => "integer"
    publish :variable => :showAllPartitions, :type => "boolean"
    publish :variable => :didSearchForRootPartitions, :type => "boolean"
    publish :variable => :targetOk, :type => "boolean"
    publish :variable => :did_try_mount_partitions, :type => "boolean"
    publish :function => :GetActivated, :type => "list <map <symbol, string>> ()"
    publish :function => :Mounted, :type => "boolean ()"
    publish :function => :GetInfoOfSelected, :type => "string (symbol)"
    publish :function => :SetSelectedToValid, :type => "void ()"
    publish :function => :UnmountPartitions, :type => "void (boolean)"
    publish :function => :AnyQuestionAnyButtonsDetails, :type => "boolean (string, string, string, string, string)"
    publish :function => :MountPartitions, :type => "boolean (string)"
    publish :function => :IncompleteInstallationDetected, :type => "boolean (string)"
    publish :function => :FindRootPartitions, :type => "void ()"
    publish :function => :GetDistroArch, :type => "string ()"
    publish :function => :mount_target, :type => "boolean ()"
    publish :function => :Detect, :type => "void ()"
  end

  RootPart = RootPartClass.new
  RootPart.main
end
