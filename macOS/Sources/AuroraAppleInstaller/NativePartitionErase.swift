#if os(macOS)
  import Foundation

  /// What Erase on the Partitions screen may delete. The screen and the
  /// helper apply this one rule to their own scans of the same disk, so a row
  /// offered as erasable is one the helper accepts, and the helper decides.
  ///
  /// Erase deletes a row's partitions and leaves their extent unallocated.
  /// It never touches what macOS or a kept startup option needs to start up:
  /// Apple's system container and Recovery partition, the running macOS, any
  /// container with a full system in it, or an EFI partition the bootloader
  /// of a startup container that stays still names.
  enum NativePartitionErase {
    static func refusal(members: [RemovalPartition], disk: NativeCollectedDisk) -> String? {
      let snapshot = disk.snapshot
      guard !members.isEmpty else { return "There’s nothing to erase here." }
      for part in members {
        switch part.type {
        case "Apple_APFS_ISC", "Apple_APFS_Recovery":
          return "Apple’s system partitions are never erased."
        case "Apple_APFS":
          guard part.uuid != snapshot.macOSStoreUUID else {
            return "The macOS you’re running is never erased."
          }
          let volumes = snapshot.containers.first { $0.storeUUID == part.uuid }?.volumes ?? []
          guard volumes.contains(where: { $0.roles == ["System"] }) else { continue }
          // Only a startup container's system may go: one with no Library,
          // which every full macOS has.
          guard let facts = disk.containers.first(where: { $0.storeUUID == part.uuid }),
            !facts.systems.isEmpty
          else {
            return
              "\(part.identifier) has a system volume that couldn’t be checked, so it can’t be told apart from a macOS installation."
          }
          if let system = facts.systems.first(where: { !$0.stub }) {
            return
              "“\(system.label)” is a macOS installation or another full system, and Erase never deletes one."
          }
        default: continue
        }
      }
      let erased = Set(members.map(\.uuid))
      for part in members where part.type == "EFI" {
        for facts in disk.containers where !erased.contains(facts.storeUUID) {
          if let system = facts.systems.first(where: {
            $0.bootPartitions?.contains(part.uuid) == true
          }) {
            return
              "“\(system.label)” starts Linux from the EFI partition \(part.identifier). Erase “\(system.label)” together with it."
          }
        }
      }
      return nil
    }

    /// The disk once `members` are gone: the free extent their space joins,
    /// with the free space on either side, as inspection will then find it.
    static func freedExtent(members: [RemovalPartition], snapshot: RemovalSnapshot)
      -> (offset: UInt64, length: UInt64)?
    {
      let erased = Set(members.map(\.uuid))
      guard let first = members.map(\.offset).min(), let last = members.map(\.end).max() else {
        return nil
      }
      var after = snapshot
      after.partitions.removeAll { erased.contains($0.uuid) }
      after.containers.removeAll { erased.contains($0.storeUUID) }
      guard !after.partitions.isEmpty, let rows = try? NativeDiskInventory.extents(after),
        let free = rows.first(where: {
          $0.partition == nil && $0.offset <= first && $0.offset + $0.length >= last
        })
      else { return nil }
      return (free.offset, NativeInspectionMath.alignDown(free.length))
    }
  }
#endif
