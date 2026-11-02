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
    /// Volume roles only a full macOS has.
    static let macOSRoles: Set<String> = ["VM", "Update"]

    static func refusal(members: [RemovalPartition], disk: NativeCollectedDisk) -> String? {
      let snapshot = disk.snapshot
      guard !members.isEmpty else { return "There’s nothing to erase here." }
      // Apple's partitions by position as well as type: the first, the last,
      // and anything before the running macOS.
      let parts = snapshot.partitions.sorted { $0.offset < $1.offset }
      let macOS = parts.first { $0.uuid == snapshot.macOSStoreUUID }
      for part in members {
        if ["Apple_APFS_ISC", "Apple_APFS_Recovery"].contains(part.type)
          || part.uuid == parts.first?.uuid || part.uuid == parts.last?.uuid
          || macOS.map({ part.offset < $0.offset }) ?? true
        {
          return "Apple’s system partitions are never erased."
        }
        guard part.type == "Apple_APFS" else { continue }
        guard part.uuid != snapshot.macOSStoreUUID else {
          return "The macOS you’re running is never erased."
        }
        guard let container = snapshot.containers.first(where: { $0.storeUUID == part.uuid })
        else {
          return
            "\(part.identifier) couldn’t be listed as an APFS container, so it can’t be told apart from a macOS installation."
        }
        guard container.volumes.contains(where: { $0.roles == ["System"] }) else { continue }
        // Only a startup container's system may go: no Library and no
        // volume only macOS has.
        guard let facts = disk.containers.first(where: { $0.storeUUID == part.uuid }),
          !facts.systems.isEmpty
        else {
          return
            "\(part.identifier) has a system volume that couldn’t be checked, so it can’t be told apart from a macOS installation."
        }
        if let system = facts.systems.first(where: { !$0.stub })
          ?? (container.volumes.contains { !macOSRoles.isDisjoint(with: $0.roles) }
            ? facts.systems.first : nil)
        {
          return
            "“\(system.label)” is a macOS installation or another full system, and Erase never deletes one."
        }
      }
      // An EFI partition stays while a kept startup container may start from it.
      let erased = Set(members.map(\.uuid))
      guard members.contains(where: { $0.type == "EFI" }) else { return nil }
      for facts in disk.containers where !erased.contains(facts.storeUUID) {
        for system in facts.systems where system.stub {
          guard let boot = system.bootPartitions else {
            return
              "The bootloader of “\(system.label)” couldn’t be read, so any EFI partition might be the one it starts from. Erase “\(system.label)” first."
          }
          if let part = members.first(where: { $0.type == "EFI" && boot.contains($0.uuid) }) {
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
