#import "JBDTCPage.h"
#import "boot_info.h"
#import "kernel/krw.h"
#import "trustcache.h"
#import <uuid/uuid.h>

#define ALLOCATED_DYNAMIC_TRUSTCACHE_SIZE 0x4000

NSMutableArray<JBDTCPage *> *gTCPages = nil;
NSMutableArray<NSNumber *> *gTCUnusedAllocations = nil;

BOOL tcPagesRecover(void) {
  NSArray *existingTCAllocations = bootInfo_getArray(@"trustcache_allocations");
  for (NSNumber *allocNum in existingTCAllocations) {
    @autoreleasepool {
      uint64_t kaddr = [allocNum unsignedLongLongValue];
      JBDTCPage *jdt = [[JBDTCPage alloc] initWithKernelAddress:kaddr];
      [gTCPages addObject:jdt];
    }
  }
  NSArray *existingUnusuedTCAllocations =
      bootInfo_getArray(@"trustcache_unused_allocations");
  if (existingUnusuedTCAllocations) {
    gTCUnusedAllocations = [existingUnusuedTCAllocations mutableCopy];
  }
  return (BOOL)existingTCAllocations;
}

void tcPagesChanged(void) {
  NSMutableArray *tcAllocations = [NSMutableArray new];
  for (JBDTCPage *page in gTCPages) {
    @autoreleasepool {
      [tcAllocations addObject:@(page.kaddr)];
    }
  }
  bootInfo_setObject(@"trustcache_allocations", tcAllocations);
  bootInfo_setObject(@"trustcache_unused_allocations", gTCUnusedAllocations);
}

@implementation JBDTCPage

- (void)updateTCPage {
  NSLog(@"[jailbreakd] updateTCPage, kaddr: 0x%llx", _kaddr);
  kwritebuf(self.kaddr, _page, ALLOCATED_DYNAMIC_TRUSTCACHE_SIZE);
}

- (instancetype)initWithKernelAddress:(uint64_t)kaddr {
  self = [super init];
  if (self) {
    _page = NULL;
    self.kaddr = kaddr;
  }
  return self;
}

- (instancetype)initAllocateAndLink {
  self = [super init];
  if (self) {
    _page = NULL;
    self.kaddr = 0;
    if (![self allocateInKernel])
      return nil;
    [self linkInKernel];
  }
  return self;
}

- (void)setKaddr:(uint64_t)kaddr {
  // No kvtouaddr :( (self.kaddr 할때 setKaddr: 호출됨)
  // Since I could't mapping kaddr to userland,
  // so... use malloc instead of kvtouaddr!
  // when you changed modify _page everytime, you had to apply into kaddr.
  //
  // NOTE: applying _page is being used by this function below
  // Read: setKaddr
  // Write: linkInKernel, addEntry, removeEntry
  // Used: setKaddr, allocateInKernel, sort, addEntry, _indexOfEntry,
  // removeEntry
  _kaddr = kaddr;
  if (kaddr) {
    NSLog(@"[jailbreakd] setKaddr: 0x%llx\n", kaddr);
    if (_page == NULL) {
      _page = (trustcache_page *)malloc(ALLOCATED_DYNAMIC_TRUSTCACHE_SIZE);
    }
    kreadbuf(kaddr, _page, ALLOCATED_DYNAMIC_TRUSTCACHE_SIZE);
  } else {
    _page = 0;
  }
}

- (BOOL)allocateInKernel {
  uint64_t kaddr = 0;
  if (gTCUnusedAllocations.count) {
    kaddr = [gTCUnusedAllocations.firstObject unsignedLongLongValue];
    [gTCUnusedAllocations removeObjectAtIndex:0];
    NSLog(@"[jailbreakd] got existing trust cache page at 0x%llX", kaddr);
  } else {
    kaddr = kalloc(ALLOCATED_DYNAMIC_TRUSTCACHE_SIZE);
  }

  if (kaddr == 0)
    return NO;
  NSLog(@"[jailbreakd] allocated trust cache page at 0x%llX", kaddr);
  self.kaddr = kaddr;

  _page->nextPtr = 0;
  _page->selfPtr = kaddr + 0x10;
  _page->file.version = 1;
  uuid_generate(_page->file.uuid);
  _page->file.length = 0;

  [gTCPages addObject:self];

  tcPagesChanged();
  return YES;
}

- (void)linkInKernel {
  [self updateTCPage];
  trustCacheListAdd(self.kaddr);
}

- (void)unlinkInKernel {
  [self updateTCPage];
  trustCacheListRemove(self.kaddr);
}

- (void)freeInKernel {
  if (self.kaddr == 0)
    return;

  [gTCUnusedAllocations addObject:@(self.kaddr)];
  NSLog(@"[jailbreakd] moved trust cache page at 0x%llX to unused list",
        self.kaddr);
  self.kaddr = 0;

  [gTCPages removeObject:self];
  tcPagesChanged();
}

- (void)unlinkAndFree {
  [self unlinkInKernel];
  [self freeInKernel];
}

- (void)sort {
  qsort(_page->file.entries, _page->file.length, sizeof(trustcache_entry),
        tcentryComparator);
}

- (uint32_t)amountOfSlotsLeft {
  return TC_ENTRY_COUNT_PER_PAGE - _page->file.length;
}

// Put entry at end, the caller of this is supposed to be calling "sort" after
// it's done adding everything desired
- (BOOL)addEntry:(trustcache_entry)entry {
  uint32_t index = _page->file.length;
  if (index >= TC_ENTRY_COUNT_PER_PAGE) {
    return NO;
  }
  _page->file.entries[index] = entry;
  _page->file.length++;

  return YES;
}

// This method only works when the entries are sorted, so the caller needs to
// ensure they are
- (int64_t)_indexOfEntry:(trustcache_entry)entry {
  trustcache_entry *entries = _page->file.entries;
  int32_t count = _page->file.length;
  int32_t left = 0;
  int32_t right = count - 1;

  while (left <= right) {
    int32_t mid = (left + right) / 2;
    int32_t cmp = memcmp(entry.hash, entries[mid].hash, CS_CDHASH_LEN);
    if (cmp == 0) {
      return mid;
    }
    if (cmp < 0) {
      right = mid - 1;
    } else {
      left = mid + 1;
    }
  }
  return -1;
}

// The idea here is to move the entry to remove to the end and then decrement
// length by one So we change it to all 0xFF's, run sort and decrement, win :D
- (BOOL)removeEntry:(trustcache_entry)entry {
  int64_t entryIndexOrNot = [self _indexOfEntry:entry];
  if (entryIndexOrNot == -1)
    return NO; // Entry isn't in here, do nothing
  uint32_t entryIndex = (uint32_t)entryIndexOrNot;

  memset(_page->file.entries[entryIndex].hash, 0xFF, CS_CDHASH_LEN);
  [self sort];
  _page->file.length--;

  return YES;
}

@end