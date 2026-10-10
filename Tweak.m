// Tweak.m — GTA San Andreas (single-player) mod menu.
// Works as a plain dylib (LiveContainer / sideloading) or as a Theos tweak on a jailbreak.
// It has no Substrate dependency. Edit Offsets.h to make the features work on your game build.
//
// How it works: a floating "M" button opens a menu. Toggles keep writing a value
// into game memory ~33 times per second; buttons write once. All reads/writes are
// done through the Mach VM API so a wrong address fails quietly instead of crashing.

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <unistd.h>
#import "Offsets.h"

static uintptr_t gSlide = 0;
static BOOL gSlideFound = NO;
static NSString *gImageName = nil;
static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;

#pragma mark - Memory helpers

static BOOL MemRead(uintptr_t addr, void *out, size_t size) {
    if (addr < 0x10000) return NO;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)size, (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == size;
}

static BOOL MemWrite(uintptr_t addr, const void *data, size_t size) {
    if (addr < 0x10000) return NO;
    kern_return_t kr = vm_write(mach_task_self(), (vm_address_t)addr, (vm_offset_t)data, (mach_msg_type_number_t)size);
    if (kr == KERN_SUCCESS) return YES;
    uintptr_t ps = (uintptr_t)getpagesize();
    vm_address_t page = (vm_address_t)(addr & ~(ps - 1));
    vm_size_t len = (vm_size_t)(((addr + size + ps - 1) & ~(ps - 1)) - page);
    vm_protect(mach_task_self(), page, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    kr = vm_write(mach_task_self(), (vm_address_t)addr, (vm_offset_t)data, (mach_msg_type_number_t)size);
    return kr == KERN_SUCCESS;
}

// Finds the game's main binary among the loaded images and caches its ASLR slide.
// It matches by CFBundleExecutable instead of "the main executable", because inside
// LiveContainer the game binary is loaded as a dylib AFTER the tweaks, so the slide
// can only be read later, once the game is running. Called lazily, never at load.
static BOOL RefreshSlide(void) {
    if (gSlideFound) return YES;
    NSString *exe = [NSBundle mainBundle].infoDictionary[@"CFBundleExecutable"];
    if (exe.length == 0) return NO;
    NSString *suffix = [@"/" stringByAppendingString:exe];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = [NSString stringWithUTF8String:name];
        if (path && [path hasSuffix:suffix]) {
            gSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            gImageName = exe;
            gSlideFound = YES;
            return YES;
        }
    }
    return NO;
}

static BOOL PathReady(const Path *p) {
    if (!p->base) return NO;
    for (int i = 0; i < p->n; i++) if (p->off[i] == NOOFF) return NO;
    return YES;
}

// Follows a pointer chain and returns the final address (0 if any hop is invalid).
static uintptr_t Resolve(const Path *p) {
    if (!PathReady(p)) return 0;
    if (!RefreshSlide()) return 0;
    uintptr_t a = p->base + gSlide;
    for (int i = 0; i < p->n; i++) {
        uintptr_t ptr = 0;
        if (!MemRead(a, &ptr, sizeof(ptr)) || ptr < 0x10000) return 0;
        a = ptr + (uintptr_t)p->off[i];
    }
    return a;
}

typedef NS_ENUM(int, VT) { VTFloat, VTInt32, VTInt16, VTInt8, VTBits32, VTAmmo };

static BOOL WriteTyped(uintptr_t a, VT t, double v, uint32_t mask, BOOL setBits) {
    switch (t) {
        case VTFloat: { float x = (float)v;    return MemWrite(a, &x, 4); }
        case VTInt32: { int32_t x = (int32_t)v; return MemWrite(a, &x, 4); }
        case VTInt16: { int16_t x = (int16_t)v; return MemWrite(a, &x, 2); }
        case VTInt8:  { int8_t x = (int8_t)v;   return MemWrite(a, &x, 1); }
        case VTBits32: {
            uint32_t cur = 0;
            if (!MemRead(a, &cur, 4)) return NO;
            uint32_t n = setBits ? (cur | mask) : (cur & ~mask);
            return n == cur ? YES : MemWrite(a, &n, 4);
        }
        default: return NO;
    }
}

#pragma mark - Feature model

@interface Feature : NSObject
@property (nonatomic, copy) NSString *section;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) Path path;
@property (nonatomic) Path path2;          // optional second target (e.g. displayed money)
@property (nonatomic) VT type;
@property (nonatomic) double value;        // value written while ON
@property (nonatomic) double minV;         // slider range (slider shown if maxV > minV)
@property (nonatomic) double maxV;
@property (nonatomic) uint32_t mask;       // bits to set/clear (VTBits32)
@property (nonatomic) BOOL oneShot;        // button: write once instead of a toggle
@property (nonatomic) BOOL hasRestore;     // write `restore` when switched off
@property (nonatomic) double restore;
@property (atomic) BOOL on;
@property (nonatomic, readonly) BOOL ready;
- (BOOL)hasSlider;
- (void)apply:(BOOL)enable;
@end

@implementation Feature

- (BOOL)hasSlider { return _maxV > _minV; }

- (BOOL)ready {
    switch (_type) {
        case VTAmmo:
            return PathReady(&_path) && OFF_PED_WEAPONS != NOOFF && WEAPON_STRIDE != NOOFF
                && WEAPON_TYPE_OFF != NOOFF && WEAPON_AMMO_OFF != NOOFF;
        case VTBits32:
            return PathReady(&_path) && _mask != 0;
        default:
            return PathReady(&_path);
    }
}

- (void)applyAmmo {
    Path pp = PATH_PLAYER_PED_OBJ;
    uintptr_t ped = Resolve(&pp);
    if (!ped) return;
    int32_t full = (int32_t)_value;
    for (int s = 0; s < 13; s++) {
        uintptr_t slot = ped + OFF_PED_WEAPONS + (uintptr_t)s * WEAPON_STRIDE;
        int32_t type = 0, ammo = 0;
        if (!MemRead(slot + WEAPON_TYPE_OFF, &type, 4)) continue;
        if (!MemRead(slot + WEAPON_AMMO_OFF, &ammo, 4)) continue;
        if (type <= 0 || type > 60 || ammo <= 0 || ammo >= full) continue;   // only refill weapons you own
        MemWrite(slot + WEAPON_AMMO_OFF, &full, 4);
    }
}

- (void)apply:(BOOL)enable {
    if (!self.ready) return;
    if (_type == VTAmmo) { if (enable) [self applyAmmo]; return; }
    Path paths[2] = { _path, _path2 };
    for (int i = 0; i < 2; i++) {
        if (!PathReady(&paths[i])) continue;
        uintptr_t a = Resolve(&paths[i]);
        if (!a) continue;
        if (enable)                    WriteTyped(a, _type, _value, _mask, YES);
        else if (_type == VTBits32)    WriteTyped(a, _type, 0, _mask, NO);
        else if (_hasRestore)          WriteTyped(a, _type, _restore, _mask, NO);
    }
}

@end

static NSMutableArray<Feature *> *gFeatures;

static Feature *Add(NSString *sec, NSString *title, Path p, VT t, double v) {
    Feature *f = [Feature new];
    f.section = sec; f.title = title; f.path = p; f.type = t; f.value = v;
    [gFeatures addObject:f];
    return f;
}

static void BuildFeatures(void) {
    gFeatures = [NSMutableArray new];
    Feature *f;
    NSString *P = @"Player", *V = @"Vehicle", *W = @"World", *C = @"Built-in cheat flags";

    // ---- Player ----
    Add(P, @"God mode (lock health)", (Path)PATH_PLAYER_HEALTH, VTFloat, 100);
    Add(P, @"Infinite armor", (Path)PATH_PLAYER_ARMOR, VTFloat, 100);
    f = Add(P, @"Invincible flags (bullet/fire/explosion/melee)", (Path)PATH_PLAYER_PHYS_FLAGS, VTBits32, 0);
    f.mask = MASK_PED_INVINCIBLE;
    Add(P, @"Never wanted", (Path)PATH_WANTED_LEVEL, VTInt32, 0);
    Add(P, @"Infinite sprint", (Path)PATH_PLAYER_SPRINT, VTFloat, 100);
    Add(P, @"Infinite breath", (Path)PATH_PLAYER_BREATH, VTFloat, 100);
    Add(P, @"Infinite ammo (owned weapons)", (Path)PATH_PLAYER_PED_OBJ, VTAmmo, 9999);

    f = Add(P, @"Set money", (Path)PATH_MONEY, VTInt32, 10000000);
    f.path2 = (Path)PATH_MONEY_DISPLAY; f.oneShot = YES; f.minV = 0; f.maxV = 999999999;
    f = Add(P, @"Max muscle", (Path)PATH_STAT_MUSCLE, VTFloat, 1000);   f.oneShot = YES;
    f = Add(P, @"Min fat", (Path)PATH_STAT_FAT, VTFloat, 0);            f.oneShot = YES;
    f = Add(P, @"Max stamina", (Path)PATH_STAT_STAMINA, VTFloat, 1000); f.oneShot = YES;
    f = Add(P, @"Max respect", (Path)PATH_STAT_RESPECT, VTFloat, 1000); f.oneShot = YES;
    f = Add(P, @"Max health bar", (Path)PATH_STAT_MAXHEALTH, VTFloat, 1000); f.oneShot = YES;

    // ---- Vehicle ----
    Add(V, @"Vehicle god mode (lock health)", (Path)PATH_VEH_HEALTH, VTFloat, 1000);
    f = Add(V, @"Vehicle proof flags", (Path)PATH_VEH_PHYS_FLAGS, VTBits32, 0);
    f.mask = MASK_VEH_PROOF;

    // ---- World ----
    f = Add(W, @"Gravity", (Path)PATH_GRAVITY, VTFloat, 0.008);
    f.minV = 0.001; f.maxV = 0.02; f.hasRestore = YES; f.restore = 0.008;
    f = Add(W, @"Game speed", (Path)PATH_TIMESCALE, VTFloat, 1.0);
    f.minV = 0.1; f.maxV = 3.0; f.hasRestore = YES; f.restore = 1.0;
    f = Add(W, @"Lock hour", (Path)PATH_CLOCK_HOURS, VTInt8, 12);
    f.minV = 0; f.maxV = 23;
    f = Add(W, @"Lock weather", (Path)PATH_FORCED_WEATHER, VTInt16, 0);
    f.minV = 0; f.maxV = 22; f.hasRestore = YES; f.restore = -1;
    f = Add(W, @"Traffic density", (Path)PATH_TRAFFIC_MULT, VTFloat, 1.0);
    f.minV = 0; f.maxV = 5; f.hasRestore = YES; f.restore = 1.0;
    f = Add(W, @"Pedestrian density", (Path)PATH_PED_MULT, VTFloat, 1.0);
    f.minV = 0; f.maxV = 5; f.hasRestore = YES; f.restore = 1.0;

    // ---- Built-in cheat flags (bytes inside the game's own cheat array) ----
#define CHEAT(name, idx) do { Path cp = { CHEATADDR(idx), 0, { 0 } }; \
    f = Add(C, name, cp, VTInt8, 1); f.hasRestore = YES; f.restore = 0; } while (0)
    CHEAT(@"Hovering cars",        CHEAT_IDX_HOVER);
    CHEAT(@"Flying cars",          CHEAT_IDX_FLYCARS);
    CHEAT(@"Cars float on water",  CHEAT_IDX_WATERCARS);
    CHEAT(@"Perfect handling",     CHEAT_IDX_HANDLING);
    CHEAT(@"Aggressive drivers",   CHEAT_IDX_AGGRO);
    CHEAT(@"Pedestrian riot",      CHEAT_IDX_RIOT);
    CHEAT(@"Pedestrians armed",    CHEAT_IDX_PEDARMED);
    CHEAT(@"Gangs everywhere",     CHEAT_IDX_GANGS);
#undef CHEAT
}

static NSString *FmtValue(Feature *f, double v) {
    BOOL isInt = f.type == VTInt32 || f.type == VTInt16 || f.type == VTInt8 || f.type == VTAmmo;
    if (isInt || (f.maxV - f.minV) > 100) return [NSString stringWithFormat:@"%.0f", v];
    return [NSString stringWithFormat:@"%.3f", v];
}

#pragma mark - Menu UI

@interface MenuView : UIView <UITableViewDataSource, UITableViewDelegate>
@end

@implementation MenuView {
    UITableView *_table;
    NSMutableArray<NSString *> *_names;
    NSMutableArray<NSMutableArray<Feature *> *> *_groups;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.92];
    self.layer.cornerRadius = 14;
    self.clipsToBounds = YES;

    _names = [NSMutableArray new];
    _groups = [NSMutableArray new];
    for (Feature *f in gFeatures) {
        NSUInteger i = [_names indexOfObject:f.section];
        if (i == NSNotFound) {
            [_names addObject:f.section];
            [_groups addObject:[NSMutableArray new]];
            i = _names.count - 1;
        }
        [_groups[i] addObject:f];
    }

    CGFloat w = frame.size.width, h = frame.size.height;
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, w - 140, 26)];
    t.text = @"GTA SA Mod Menu";
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:18];
    [self addSubview:t];

    UIButton *off = [UIButton buttonWithType:UIButtonTypeSystem];
    off.frame = CGRectMake(w - 118, 10, 104, 30);
    [off setTitle:@"Disable all" forState:UIControlStateNormal];
    [off addTarget:self action:@selector(disableAll) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:off];

    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 44, w - 32, 16)];
    if (RefreshSlide())
        s.text = [NSString stringWithFormat:@"%@ slide: 0x%lx   (static address = runtime address - slide)", gImageName, (unsigned long)gSlide];
    else
        s.text = @"game binary not found (CFBundleExecutable mismatch)";
    s.textColor = UIColor.lightGrayColor;
    s.font = [UIFont systemFontOfSize:11];
    s.adjustsFontSizeToFitWidth = YES;
    [self addSubview:s];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 66, w, h - 66) style:UITableViewStyleGrouped];
    _table.backgroundColor = UIColor.clearColor;
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.12];
    _table.dataSource = self;
    _table.delegate = self;
    [self addSubview:_table];
    return self;
}

- (void)disableAll {
    for (Feature *f in gFeatures) {
        if (!f.on) continue;
        f.on = NO;
        dispatch_async(gQueue, ^{ [f apply:NO]; });
    }
    [_table reloadData];
}

- (UIView *)controlFor:(Feature *)f index:(NSInteger)idx {
    BOOL slider = f.hasSlider;
    CGFloat x = 0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, slider ? 256 : 80, 36)];
    if (slider) {
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 3, 120, 30)];
        sl.minimumValue = (float)f.minV;
        sl.maximumValue = (float)f.maxV;
        sl.value = (float)f.value;
        sl.tag = idx + 100;
        [sl addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        [box addSubview:sl];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(124, 8, 62, 20)];
        l.tag = 1;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        l.adjustsFontSizeToFitWidth = YES;
        l.text = FmtValue(f, f.value);
        [box addSubview:l];
        x = 190;
    }
    if (f.oneShot) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 3, 64, 30);
        b.tag = idx + 100;
        b.layer.cornerRadius = 8;
        b.backgroundColor = [UIColor colorWithRed:0.1 green:0.45 blue:0.9 alpha:1];
        [b setTitle:@"Apply" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [b addTarget:self action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:b];
    } else {
        UISwitch *sw = [UISwitch new];
        sw.frame = CGRectMake(x, 3, 51, 31);
        sw.tag = idx + 100;
        sw.on = f.on;
        [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        [box addSubview:sw];
    }
    return box;
}

- (void)toggled:(UISwitch *)sw {
    Feature *f = gFeatures[sw.tag - 100];
    if (!f.ready) { [sw setOn:NO animated:YES]; return; }
    f.on = sw.on;
    if (!sw.on) dispatch_async(gQueue, ^{ [f apply:NO]; });
}

- (void)fire:(UIButton *)b {
    Feature *f = gFeatures[b.tag - 100];
    if (!f.ready) return;
    dispatch_async(gQueue, ^{ [f apply:YES]; });
}

- (void)sliderMoved:(UISlider *)s {
    Feature *f = gFeatures[s.tag - 100];
    f.value = s.value;
    UILabel *l = (UILabel *)[s.superview viewWithTag:1];
    l.text = FmtValue(f, f.value);
}

#pragma mark table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _names.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _groups[s].count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _names[s]; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 56; }

- (void)tableView:(UITableView *)tv willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    if ([view isKindOfClass:UITableViewHeaderFooterView.class])
        ((UITableViewHeaderFooterView *)view).textLabel.textColor = [UIColor colorWithRed:0.4 green:0.75 blue:1 alpha:1];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    Feature *f = _groups[ip.section][ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.backgroundColor = UIColor.clearColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.text = f.title;
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    c.textLabel.adjustsFontSizeToFitWidth = YES;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    if (f.ready) {
        c.detailTextLabel.text = @"ready";
        c.detailTextLabel.textColor = [UIColor colorWithRed:0.4 green:0.85 blue:0.5 alpha:1];
    } else {
        c.detailTextLabel.text = @"offset not set in Offsets.h";
        c.detailTextLabel.textColor = [UIColor colorWithRed:1 green:0.6 blue:0.2 alpha:1];
    }
    c.accessoryView = [self controlFor:f index:(NSInteger)[gFeatures indexOfObject:f]];
    return c;
}

@end

#pragma mark - Floating button

static MenuView *gMenu;

@interface Fab : UIButton
@end

@implementation Fab

- (instancetype)init {
    self = [super initWithFrame:CGRectMake(24, 140, 52, 52)];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.1 green:0.45 blue:0.9 alpha:0.9];
    self.layer.cornerRadius = 26;
    self.layer.borderWidth = 2;
    self.layer.borderColor = UIColor.whiteColor.CGColor;
    [self setTitle:@"M" forState:UIControlStateNormal];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [self addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    return self;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:self.superview];
}

- (void)tap {
    UIView *host = self.superview;
    if (!host) return;
    if (gMenu.superview) { [gMenu removeFromSuperview]; gMenu = nil; return; }
    CGRect b = host.bounds;
    CGFloat w = MIN(500, b.size.width - 24);
    CGFloat h = MIN(620, b.size.height - 90);
    gMenu = [[MenuView alloc] initWithFrame:CGRectMake((b.size.width - w) / 2, 50, w, h)];
    [host insertSubview:gMenu belowSubview:self];
}

@end

static Fab *gFab;

static void InstallOverlay(void) {
    UIWindow *win = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden) { win = w; break; }
    }
    if (!win) return;
    if (!gFab) gFab = [Fab new];
    if (gFab.superview != win) [win addSubview:gFab];
    if (gMenu.superview == win) [win bringSubviewToFront:gMenu];
    [win bringSubviewToFront:gFab];
}

#pragma mark - Entry point

static void StartWriter(void) {
    gQueue = dispatch_queue_create("gtasa.menu.writer", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        for (Feature *f in gFeatures) {
            if (f.on && !f.oneShot) [f apply:YES];
        }
    });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void GTASAMenuInit(void) {
    @autoreleasepool {
        BuildFeatures();
        StartWriter();
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { InstallOverlay(); }];
        });
    }
}
