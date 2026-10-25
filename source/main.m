#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/hid/IOHIDManager.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>

@interface Light : NSObject
@property IOHIDManagerRef manager;
@property IOHIDDeviceRef device;
@property BOOL valid, power, autoMode, videoMode, presenceEnabled;
@property int awayIndex,sensitivity;
@property BOOL presenceKnown;
@property uint8_t lastAckCommand;
@property BOOL lastAckSuccess;
@property int brightness, kelvin;
@property NSString *message;
@property(copy) void (^changed)(void);
- (void)connect;
- (BOOL)send:(uint8_t)command bytes:(const uint8_t *)bytes count:(size_t)n;
- (void)query;
- (void)receive:(uint8_t *)bytes length:(CFIndex)n;
@end
static uint8_t reportBuffer[64];
static void input(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex length) {
    if(result == kIOReturnSuccess && reportID == 2) [(__bridge Light *)ctx receive:report length:length];
}
@implementation Light
- (instancetype)init { if((self=[super init])) { _message=@"正在连接…"; _brightness=50; _kelvin=4000; } return self; }
- (void)disconnect {
    if(_device) { IOHIDDeviceUnscheduleFromRunLoop(_device,CFRunLoopGetMain(),kCFRunLoopDefaultMode); IOHIDDeviceClose(_device,0); CFRelease(_device); _device=NULL; }
    if(_manager) { IOHIDManagerClose(_manager,0); CFRelease(_manager); _manager=NULL; }
    _valid=NO;
}
- (void)connect {
    [self disconnect];
    _manager=IOHIDManagerCreate(kCFAllocatorDefault,0);
    NSDictionary *match=@{@"VendorID":@0x04a5,@"ProductID":@0x2501};
    IOHIDManagerSetDeviceMatching(_manager,(__bridge CFDictionaryRef)match);
    IOReturn result=IOHIDManagerOpen(_manager,0);
    if(result!=0) { _message=[NSString stringWithFormat:@"USB 访问失败（0x%08x）",result]; if(_changed)_changed(); return; }
    CFSetRef devices=IOHIDManagerCopyDevices(_manager);
    if(devices) {
        for(id object in (__bridge NSSet *)devices) {
            IOHIDDeviceRef candidate=(__bridge IOHIDDeviceRef)object;
            result=IOHIDDeviceOpen(candidate,0);
            if(result==0) { _device=(IOHIDDeviceRef)CFRetain(candidate); break; }
        }
        CFRelease(devices);
    }
    if(!_device) { _message=@"未找到挂灯，请检查 USB 连接"; if(_changed)_changed(); return; }
    IOHIDDeviceRegisterInputReportCallback(_device,reportBuffer,sizeof(reportBuffer),input,(__bridge void *)self);
    IOHIDDeviceScheduleWithRunLoop(_device,CFRunLoopGetMain(),kCFRunLoopDefaultMode);
    _message=@"已连接，读取状态…";
    [self query];
    if(_changed)_changed();
}
- (BOOL)send:(uint8_t)command bytes:(const uint8_t *)bytes count:(size_t)n {
    if(!_device || n>28) return NO;
    uint8_t out[33]={1,0xf0,command,(uint8_t)(n+4),0};
    unsigned sum=out[1]+out[2]+out[3];
    for(size_t i=0;i<n;i++){out[5+i]=bytes[i];sum+=bytes[i];}
    out[4]=sum&255;
    IOReturn result=IOHIDDeviceSetReport(_device,kIOHIDReportTypeOutput,1,out,sizeof(out));
    if(result!=0){[self disconnect];_message=[NSString stringWithFormat:@"发送失败（0x%08x），请重新连接",result];if(_changed)_changed();return NO;}
    return YES;
}
- (void)query { uint8_t once=0; [self send:0x20 bytes:&once count:1]; }
- (void)receive:(uint8_t *)b length:(CFIndex)n {
    // Input: report ID, E1, command, frame length, checksum, result, payload.
    if(n>=6&&b[0]==2&&b[1]==0xe1&&b[3]>=5&&b[3]+1<=n){
        unsigned checksum=0;for(int i=1;i<=b[3];i++)if(i!=4)checksum+=b[i];
        if((checksum&255)!=b[4])return;
        _lastAckCommand=b[2];_lastAckSuccess=b[5]==1;
        if(b[2]==0x24&&n>=8&&b[5]==1&&b[6]<=2&&b[7]<=2){_awayIndex=b[6];_sensitivity=b[7];_presenceKnown=YES;if(_changed)_changed();return;}
    }
    if(n<14 || b[0]!=2 || b[1]!=0xe1 || b[2]!=0x20 || b[3]<13 || b[3]+1>n || b[5]!=1) return;
    unsigned sum=0;for(int i=1;i<=b[3];i++)if(i!=4)sum+=b[i];
    if((sum&255)!=b[4])return;
    int kelvin=(b[8]<<8)|b[9], brightness=b[10];
    if(kelvin<2700 || kelvin>6500 || brightness>100)return;
    _power=(b[6]&1)!=0; _brightness=brightness; _kelvin=kelvin; _valid=YES;
    _autoMode=(b[6]&6)==4;_videoMode=(b[6]&128)!=0;_presenceEnabled=(b[6]&96)==32;
    _message=@"已连接";
    if(_changed)_changed();
}
@end

static NSUserDefaults *Settings(void) {
    static NSUserDefaults *defaults;static dispatch_once_t once;
    dispatch_once(&once,^{defaults=[NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"]?[[NSUserDefaults alloc]initWithSuiteName:@"local.barlight.testing"]:NSUserDefaults.standardUserDefaults;});return defaults;
}
@interface FakeLight : Light
@property NSMutableArray *commands;
@property BOOL delayBrightness;
@end
@implementation FakeLight
- (void)connect {self.commands=[NSMutableArray new];self.valid=YES;self.power=YES;self.brightness=30;self.kelvin=4000;self.presenceKnown=YES;self.sensitivity=2;self.message=@"测试设备";if(self.changed)self.changed();}
- (void)query {if(self.changed)self.changed();}
- (BOOL)send:(uint8_t)command bytes:(const uint8_t*)b count:(size_t)n {
    [self.commands addObject:@(command)];if(command==3&&n==4)self.kelvin=(b[0]<<8)|b[1];if(command==4&&n==2&&!self.delayBrightness)self.brightness=b[0];if(command==7&&n==1)self.power=b[0];if(command==1)self.autoMode=YES;if(command==4)self.autoMode=NO;if(command==6)self.presenceEnabled=b[0];if(command==9)self.videoMode=b[0];if(command==0x23&&n==2){self.awayIndex=b[0];self.sensitivity=b[1];self.presenceKnown=YES;}return YES;
}
- (void)disconnect {}
@end

// Both sliders share identical geometry and a single drawing pass.
static NSColor *rgb(CGFloat r,CGFloat g,CGFloat b){return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];}
@interface CardButton : NSButton
@property(nonatomic) BOOL card,active,settingsAction;
@end
@implementation CardButton
- (NSEdgeInsets)alignmentRectInsets {return self.card?NSEdgeInsetsMake(0,0,0,0):[super alignmentRectInsets];}
- (void)setActive:(BOOL)active {_active=active;self.needsDisplay=YES;}
- (void)drawRect:(NSRect)rect {
    if(self.settingsAction){
        [[NSColor.labelColor colorWithAlphaComponent:self.highlighted?.18:.09]setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:9 yRadius:9]fill];
        NSMutableParagraphStyle*style=[NSMutableParagraphStyle new];style.alignment=NSTextAlignmentCenter;
        [self.title drawInRect:NSMakeRect(4,(NSHeight(self.bounds)-18)/2,NSWidth(self.bounds)-8,18) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],NSForegroundColorAttributeName:self.enabled?NSColor.labelColor:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:style}];return;
    }
    if(!self.card){[super drawRect:rect];return;}
    NSColor *tint=self.active?[NSColor colorWithWhite:.16 alpha:1]:(self.contentTintColor?:NSColor.labelColor);
    if(!self.enabled)tint=[tint colorWithAlphaComponent:.4];
    [(self.active?[NSColor.whiteColor colorWithAlphaComponent:self.highlighted?.85:1]:[NSColor.labelColor colorWithAlphaComponent:self.highlighted?.16:.075])setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:10 yRadius:10]fill];
    BOOL titled=self.title.length>0;CGFloat side=titled?19:16;
    NSRect iconRect=NSMakeRect((NSWidth(self.bounds)-side)/2,titled?9:(NSHeight(self.bounds)-side)/2,side,side);
    NSImage *source=self.image;
    NSImage *colored=[NSImage imageWithSize:NSMakeSize(side,side) flipped:NO drawingHandler:^BOOL(NSRect r){
        NSSize natural=source.size;
        CGFloat scale=MIN(NSWidth(r)/MAX(1,natural.width),NSHeight(r)/MAX(1,natural.height));
        NSSize fitted=NSMakeSize(natural.width*scale,natural.height*scale);
        NSRect target=NSMakeRect(NSMidX(r)-fitted.width/2,NSMidY(r)-fitted.height/2,fitted.width,fitted.height);
        [source drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
        [tint setFill];NSRectFillUsingOperation(r,NSCompositingOperationSourceAtop);return YES;
    }];
    [colored drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    if(titled){NSMutableParagraphStyle*style=[NSMutableParagraphStyle new];style.alignment=NSTextAlignmentCenter;style.lineBreakMode=NSLineBreakByTruncatingTail;
        [self.title drawInRect:NSMakeRect(5,36,NSWidth(self.bounds)-10,15) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],NSForegroundColorAttributeName:tint,NSParagraphStyleAttributeName:style}];}
}

@end

@interface NeutralCheck : NSButton
@end
@implementation NeutralCheck
- (void)drawRect:(NSRect)dirty {
    CGFloat y=(NSHeight(self.bounds)-16)/2;NSRect box=NSMakeRect(2,y,16,16);NSBezierPath*shape=[NSBezierPath bezierPathWithRoundedRect:box xRadius:4 yRadius:4];
    [(self.state?NSColor.blackColor:[NSColor colorWithWhite:.65 alpha:.25])setFill];[shape fill];
    if(self.state){[NSColor.whiteColor setStroke];NSBezierPath*check=[NSBezierPath bezierPath];[check moveToPoint:NSMakePoint(5,y+8)];[check lineToPoint:NSMakePoint(9,y+12)];[check lineToPoint:NSMakePoint(15,y+4)];check.lineWidth=1.8;[check stroke];}
    NSColor*text=self.enabled?NSColor.labelColor:NSColor.secondaryLabelColor;
    [self.title drawInRect:NSMakeRect(26,(NSHeight(self.bounds)-19)/2,NSWidth(self.bounds)-28,19) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:text}];
}
@end
@interface NeutralRow : NSTableRowView
@end
@implementation NeutralRow
- (void)drawSelectionInRect:(NSRect)dirty {
    NSRect row=self.bounds,visible=self.visibleRect;
    row.origin.x=MAX(NSMinX(row),NSMinX(visible));row.size.width=MAX(0,MIN(NSMaxX(self.bounds),NSMaxX(visible))-row.origin.x);
    [[NSColor.labelColor colorWithAlphaComponent:.09]setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row,4,3) xRadius:9 yRadius:9]fill];
}
- (NSBackgroundStyle)interiorBackgroundStyle {return NSBackgroundStyleNormal;}
@end

@interface SceneListFrame : NSView
@end
@implementation SceneListFrame
- (NSView*)hitTest:(NSPoint)point {return nil;}
- (void)drawRect:(NSRect)dirty {
    NSBezierPath*outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:14 yRadius:14];
    [[NSColor.labelColor colorWithAlphaComponent:.035]setFill];[outline fill];
}
@end

@interface SettingsSurface : NSView
@end
@implementation SettingsSurface
- (void)viewDidChangeEffectiveAppearance {[super viewDidChangeEffectiveAppearance];self.needsDisplay=YES;}
- (void)drawRect:(NSRect)rect {
    BOOL dark=[[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]]isEqual:NSAppearanceNameDarkAqua];
    [[NSColor colorWithWhite:dark?.16:1 alpha:.8]setFill];[[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:18 yRadius:18]fill];
}
@end

@interface SettingsNavigationButton : NSButton
@end
@implementation SettingsNavigationButton
- (void)drawRect:(NSRect)dirty {
    BOOL selected=self.state==NSControlStateValueOn;
    NSColor*tint=selected?NSColor.whiteColor:NSColor.labelColor;
    if(selected||self.highlighted){[(selected?NSColor.blackColor:[NSColor.labelColor colorWithAlphaComponent:.06])setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:12 yRadius:12]fill];}
    NSImage*source=self.image;
    NSImage*icon=[NSImage imageWithSize:NSMakeSize(19,19) flipped:NO drawingHandler:^BOOL(NSRect r){NSSize size=source.size;CGFloat f=MIN(19/MAX(1,size.width),19/MAX(1,size.height));NSRect fit=NSMakeRect((19-size.width*f)/2,(19-size.height*f)/2,size.width*f,size.height*f);[source drawInRect:fit];[tint setFill];NSRectFillUsingOperation(r,NSCompositingOperationSourceAtop);return YES;}];
    [icon drawInRect:NSMakeRect(14,(NSHeight(self.bounds)-19)/2,19,19) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.title drawInRect:NSMakeRect(44,(NSHeight(self.bounds)-18)/2,NSWidth(self.bounds)-52,18) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:selected?NSFontWeightSemibold:NSFontWeightRegular],NSForegroundColorAttributeName:tint}];
}
@end

@interface LiveSlider : NSSlider
@property BOOL dragging,temperature;
@end
@implementation LiveSlider
- (BOOL)acceptsFirstResponder {return YES;}
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat width=self.bounds.size.width,mid=NSMidY(self.bounds);
    NSRect track=NSMakeRect(2,mid-11,width-4,22);
    NSBezierPath *capsule=[NSBezierPath bezierPathWithRoundedRect:track xRadius:11 yRadius:11];
    CGFloat t=(self.doubleValue-self.minValue)/MAX(1,self.maxValue-self.minValue);
    [NSGraphicsContext saveGraphicsState];
    if(self.temperature){NSGradient*g=[[NSGradient alloc]initWithColors:@[rgb(.31,.62,.78),rgb(.65,.71,.73),rgb(.92,.80,.37)]];[g drawInBezierPath:capsule angle:0];}
    else{
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow=[NSShadow new];shadow.shadowColor=[NSColor.blackColor colorWithAlphaComponent:.16];shadow.shadowBlurRadius=2;shadow.shadowOffset=NSMakeSize(0,-.5);[shadow set];
        [NSColor.whiteColor setFill];[capsule fill];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor.blackColor colorWithAlphaComponent:.16]setStroke];capsule.lineWidth=.6;[capsule stroke];
    }
    NSRect knob=NSMakeRect(12+t*(width-24)-8.5,mid-8.5,17,17);
    NSBezierPath *thumb=[NSBezierPath bezierPathWithOvalInRect:knob];
    if(self.temperature){
        [[NSColor colorWithWhite:1 alpha:.22]setFill];[thumb fill];[NSColor.whiteColor setStroke];thumb.lineWidth=1.6;[thumb stroke];
    }else{
        [NSGraphicsContext saveGraphicsState];NSShadow*shadow=[NSShadow new];shadow.shadowColor=[NSColor.blackColor colorWithAlphaComponent:.3];shadow.shadowBlurRadius=2;shadow.shadowOffset=NSMakeSize(0,-.5);[shadow set];
        [[NSColor colorWithWhite:.93 alpha:1]setFill];[thumb fill];[NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithWhite:.48 alpha:1]setStroke];thumb.lineWidth=1;[thumb stroke];
    }
    if(!self.enabled){[[NSColor.windowBackgroundColor colorWithAlphaComponent:.5]setFill];[capsule fill];}
    [NSGraphicsContext restoreGraphicsState];
}
- (void)setDoubleValue:(double)value {[super setDoubleValue:MAX(self.minValue,MIN(self.maxValue,value))];self.needsDisplay=YES;}
- (void)updateWithEvent:(NSEvent*)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    self.doubleValue=self.minValue+MAX(0,MIN(1,(p.x-12)/MAX(1,self.bounds.size.width-24)))*(self.maxValue-self.minValue);
    [self sendAction:self.action to:self.target];
}
- (void)mouseDown:(NSEvent*)event {
    if(!self.enabled)return;[self.window makeFirstResponder:self];self.dragging=YES;[self updateWithEvent:event];
    while(YES){NSEvent*next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];if(!next)break;
        if(next.type==NSEventTypeLeftMouseUp){self.dragging=NO;[self updateWithEvent:next];break;}[self updateWithEvent:next];}
    self.dragging=NO;self.needsDisplay=YES;
}
- (void)keyDown:(NSEvent*)event {
    switch(event.keyCode){case 123:case 125:self.doubleValue-=1;break;case 124:case 126:self.doubleValue+=1;break;default:[super keyDown:event];return;}
    [self sendAction:self.action to:self.target];
}
@end

static NSImage *SceneIcon(NSString *symbol,NSString *label){
    NSString *name=[symbol isEqual:@"desktopcomputer"]?@"scope":symbol;
    NSImage *image=[NSImage imageWithSystemSymbolName:name accessibilityDescription:label];
    return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:19 weight:NSFontWeightRegular]];

}
static NSArray *DefaultPresets(void){return @[
@{@"id":@"focus",@"name":@"专注",@"icon":@"desktopcomputer",@"brightness":@65,@"kelvin":@4500},
@{@"id":@"read",@"name":@"阅读",@"icon":@"book",@"brightness":@50,@"kelvin":@3800},
@{@"id":@"relax",@"name":@"放松",@"icon":@"cup.and.saucer",@"brightness":@25,@"kelvin":@3000},
@{@"id":@"night",@"name":@"夜间",@"icon":@"moon.stars",@"brightness":@10,@"kelvin":@2700}];}
static NSDictionary *FindPreset(NSArray*presets,NSString*identifier){for(NSDictionary*p in presets)if([p[@"id"]isEqual:identifier])return p;return nil;}
static NSString *RulePreset(NSArray*rules,NSString*bundle){for(NSDictionary*r in rules)if([r[@"bundle"]isEqual:bundle])return r[@"preset"];return nil;}

// A dedicated vector template, redrawn at menu-bar scale; no app-icon background.
static NSImage *MenuBarSymbol(void) {
    NSImage *image=[NSImage imageWithSize:NSMakeSize(20,20) flipped:NO drawingHandler:^BOOL(NSRect rect){
        [NSColor.blackColor setFill];[NSColor.blackColor setStroke];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2,13,16,3) xRadius:1.5 yRadius:1.5]fill];
        NSBezierPath *rays=[NSBezierPath bezierPath];rays.lineWidth=1.5;rays.lineCapStyle=NSLineCapStyleRound;
        [rays moveToPoint:NSMakePoint(6,9.5)];[rays lineToPoint:NSMakePoint(4.5,4.5)];
        [rays moveToPoint:NSMakePoint(10,9.5)];[rays lineToPoint:NSMakePoint(10,3.5)];
        [rays moveToPoint:NSMakePoint(14,9.5)];[rays lineToPoint:NSMakePoint(15.5,4.5)];[rays stroke];return YES;
    }];
    image.template=YES;image.accessibilityDescription=@"Luma 挂灯";return image;
}


static BOOL ReadNightShift(BOOL *enabled,float *strength){
    static id client;static dispatch_once_t once;
    dispatch_once(&once,^{dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_LAZY);Class c=NSClassFromString(@"CBBlueLightClient");if(c)client=[c new];});
    SEL status=NSSelectorFromString(@"getBlueLightStatus:");SEL amount=NSSelectorFromString(@"getStrength:");
    if(!client||![client respondsToSelector:status])return NO;
    unsigned char buffer[512]={0};BOOL ok=((BOOL(*)(id,SEL,void*))objc_msgSend)(client,status,buffer);if(!ok)return NO;
    *enabled=buffer[1]!=0;*strength=.5;
    if([client respondsToSelector:amount])((BOOL(*)(id,SEL,float*))objc_msgSend)(client,amount,strength);
    *strength=MAX(0,MIN(1,*strength));return YES;
}
static NSDictionary *LightState(Light*l){return @{@"brightness":@(l.brightness),@"kelvin":@(l.kelvin),@"power":@(l.power),@"auto":@(l.autoMode),@"video":@(l.videoMode)};}
static int WarmKelvin(int base,float strength){return MAX(2700,MIN(6500,(int)(round((base-(base-2700)*strength)/25.0)*25)));}
@interface App : NSObject <NSApplicationDelegate,NSPopoverDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate>
@property Light *light;
@property NSStatusItem *item;
@property NSPopover *popover;
@property NSView *panelContent;
@property LiveSlider *brightness,*temperature,*sceneBrightness,*sceneTemperature;
@property NSTextField *brightnessLabel,*kelvinLabel,*connection,*settingsMessage,*nameField,*brightnessField,*kelvinField,*systemStatus;
@property NSButton *powerButton,*autoButton,*videoButton,*presenceButton,*automationSwitch,*presenceSwitch,*wakeSwitch,*cameraSwitch,*nightSwitch,*sleepSwitch;
@property NSPopUpButton *iconPicker,*awayPicker,*idlePicker;
@property NSSegmentedControl *tabs,*sensitivityPicker;
@property NSMutableArray<NSButton*> *presetButtons;
@property NSMutableArray *presets,*rules;
@property NSWindow *settings;
@property NSTableView *sceneTable,*ruleTable;
@property NSArray<NSView*> *panes;
@property NSArray *icons;
@property NSTimer *timer;
@property BOOL busy,loading,sleeping,pendingWake,softwareOff,cameraManaged,lastCamera,nightManaged,lastNight;
@property NSUInteger generation,editGeneration;
@property uint8_t pendingMode;
@property BOOL pendingModeValue;
@property NSTimeInterval modeStarted;
@property NSInteger selectedScene;
@property NSTimeInterval lastWrite,lastNightPoll,idleBaseline;
@property NSString *pendingPreset,*lastExternalBundle;
@property NSDictionary *softwareRestore,*cameraRestore;
@property int nightBase;
@property float lastNightStrength;
@property EventHotKeyRef dimHotKey,brightHotKey;
@property EventHandlerRef hotKeyHandler;
@property NSString *hotKeyStatus;
@property NSTimer *brightnessRepeatTimer;
@property NSInteger heldBrightnessKey;
@property NSString *activePresetID;
@property NSArray<NSButton*> *settingsNavigation;
@property NSTextField *settingsHeading,*settingsSubtitle;
@property NSArray<NSPopUpButton*> *shortcutKeys;
@property NSArray<NSArray<NSButton*>*> *shortcutModifiers;
@property NSTextField *shortcutStatus;
@property BOOL shortcutPending;
@property int shortcutBrightness;
@property NSTimeInterval shortcutLastUsed;
- (void)adjustBrightnessShortcut:(NSInteger)delta;
- (void)brightnessKey:(NSInteger)identifier pressed:(BOOL)pressed;
- (void)stopBrightnessRepeat;
- (void)refresh;
- (void)applyPreset:(NSDictionary*)preset;
- (void)runTests;
@end
static OSStatus BrightnessHotKeyHandler(EventHandlerCallRef next,EventRef event,void *context){
    EventHotKeyID identifier={0};OSStatus result=GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(identifier),NULL,&identifier);
    if(result!=noErr||identifier.signature!=0x69436872||(identifier.id!=1&&identifier.id!=2))return eventNotHandledErr;
    App *app=(__bridge App*)context;BOOL pressed=GetEventKind(event)==kEventHotKeyPressed;
    dispatch_async(dispatch_get_main_queue(),^{[app brightnessKey:identifier.id pressed:pressed];});return noErr;
}
@implementation App
- (NSTextField*)label:(NSString*)text size:(CGFloat)size frame:(NSRect)frame view:(NSView*)view {
    NSTextField*l=[NSTextField labelWithString:text];l.frame=frame;l.font=[NSFont systemFontOfSize:size];[view addSubview:l];return l;
}
- (NSButton*)button:(NSString*)title frame:(NSRect)frame action:(SEL)action view:(NSView*)v {
    NSButton*b=[CardButton buttonWithTitle:title target:self action:action];b.frame=frame;b.bezelStyle=NSBezelStyleRounded;[v addSubview:b];return b;
}
- (NSButton*)symbol:(NSString*)symbol label:(NSString*)label frame:(NSRect)frame action:(SEL)action view:(NSView*)v {
    NSButton*b=[self button:@"" frame:frame action:action view:v];b.bordered=NO;((CardButton*)b).card=YES;b.image=SceneIcon(symbol,label);b.toolTip=label;return b;
}
- (LiveSlider*)slider:(BOOL)temperature frame:(NSRect)frame action:(SEL)action view:(NSView*)v {
    LiveSlider*s=[[LiveSlider alloc]initWithFrame:frame];s.focusRingType=NSFocusRingTypeNone;s.temperature=temperature;s.minValue=0;s.maxValue=100;s.continuous=YES;s.target=self;s.action=action;s.accessibilityLabel=temperature?@"色温，左冷右暖":@"亮度";[v addSubview:s];return s;
}
- (NSTextField*)field:(NSRect)frame view:(NSView*)v {NSTextField*f=[[NSTextField alloc]initWithFrame:frame];f.font=[NSFont systemFontOfSize:13];f.delegate=self;[v addSubview:f];return f;}
- (NSButton*)check:(NSString*)text frame:(NSRect)frame action:(SEL)action view:(NSView*)v {NSButton*b=[NeutralCheck checkboxWithTitle:text target:self action:action];b.frame=frame;[v addSubview:b];return b;}
- (NSPopUpButton*)picker:(NSRect)frame items:(NSArray*)items action:(SEL)action view:(NSView*)v {NSPopUpButton*p=[[NSPopUpButton alloc]initWithFrame:frame pullsDown:NO];[p addItemsWithTitles:items];p.focusRingType=NSFocusRingTypeNone;p.contentTintColor=NSColor.labelColor;p.target=self;p.action=action;[v addSubview:p];return p;}
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    [Settings() registerDefaults:@{@"previewSelection.v3":@YES}];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"])[Settings() removePersistentDomainForName:@"local.barlight.testing"];
    _presets=[[Settings() arrayForKey:@"presets.v2"]mutableCopy]?:[DefaultPresets()mutableCopy];_rules=[[Settings() arrayForKey:@"rules.v2"]mutableCopy]?:[NSMutableArray new];
    _icons=@[@"desktopcomputer",@"book",@"cup.and.saucer",@"moon.stars",@"sun.max",@"gamecontroller",@"film",@"lightbulb"];
    _presetButtons=[NSMutableArray new];_selectedScene=0;_lastExternalBundle=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;_idleBaseline=NSDate.timeIntervalSinceReferenceDate;
    _light=[NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"]?[FakeLight new]:[Light new];__weak App*weak=self;
    _light.changed=^{App*s=weak;if(!s)return;[s refresh];if(s.light.lastAckCommand==0x24&&s.light.presenceKnown&&[s.settingsMessage.stringValue isEqual:@"已发送，正在读取挂灯设置…"])s.settingsMessage.stringValue=@"挂灯侦测设置已回读确认。";if(s.pendingWake&&s.light.valid){s.pendingWake=NO;uint8_t on=1;[s.light send:7 bytes:&on count:1];}[s applyPending];};
    _item=[NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];_item.button.image=MenuBarSymbol();_item.button.target=self;_item.button.action=@selector(togglePopover:);
    _popover=[NSPopover new];_popover.behavior=NSPopoverBehaviorTransient;_popover.delegate=self;_popover.animates=NO;
    NSViewController*vc=[NSViewController new];NSView*v=[[NSView alloc]initWithFrame:NSMakeRect(0,0,336,360)];_panelContent=v;vc.view=v;_popover.contentViewController=vc;
    NSTextField*t=[self label:@"Luma" size:17 frame:NSMakeRect(24,312,170,24) view:v];t.font=[NSFont systemFontOfSize:17 weight:NSFontWeightSemibold];
    _powerButton=[self symbol:@"power" label:@"开关灯" frame:NSMakeRect(248,309,30,30) action:@selector(togglePower:) view:v];
    [self symbol:@"gearshape" label:@"设置" frame:NSMakeRect(286,309,30,30) action:@selector(showSettings:) view:v];[self buildPresetButtons];
    [self label:@"亮度" size:12 frame:NSMakeRect(24,205,140,22) view:v];_brightnessLabel=[self label:@"—" size:12 frame:NSMakeRect(220,205,92,22) view:v];_brightnessLabel.alignment=NSTextAlignmentRight;
    _brightness=[self slider:NO frame:NSMakeRect(22,169,292,34) action:@selector(changeBrightness:) view:v];
    [self label:@"色温" size:12 frame:NSMakeRect(24,129,140,22) view:v];_kelvinLabel=[self label:@"—" size:12 frame:NSMakeRect(220,129,92,22) view:v];_kelvinLabel.alignment=NSTextAlignmentRight;
    _temperature=[self slider:YES frame:NSMakeRect(22,93,292,34) action:@selector(changeTemperature:) view:v];
    _autoButton=[self symbol:@"a.circle" label:@"自动调光" frame:NSMakeRect(40,38,38,32) action:@selector(toggleAuto:) view:v];
    _videoButton=[self symbol:@"video" label:@"视频模式" frame:NSMakeRect(149,38,38,32) action:@selector(toggleVideo:) view:v];
    _presenceButton=[self symbol:@"figure.walk" label:@"入离席侦测" frame:NSMakeRect(258,38,38,32) action:@selector(togglePresence:) view:v];
    NSArray*controls=@[_autoButton,_videoButton,_presenceButton];NSArray*titles=@[@"自动调光",@"视频模式",@"入离席"];
    NSStackView*controlRow=[[NSStackView alloc]initWithFrame:NSMakeRect(24,22,NSWidth(v.bounds)-48,58)];controlRow.orientation=NSUserInterfaceLayoutOrientationHorizontal;controlRow.distribution=NSStackViewDistributionFillEqually;controlRow.alignment=NSLayoutAttributeCenterY;controlRow.spacing=6;controlRow.autoresizingMask=NSViewWidthSizable;
    for(NSUInteger i=0;i<controls.count;i++){CardButton*b=controls[i];b.card=YES;b.title=titles[i];[b removeFromSuperview];[controlRow addArrangedSubview:b];[b.heightAnchor constraintEqualToConstant:58].active=YES;}
    [v addSubview:controlRow];
    _connection=[self label:@"连接中…" size:10 frame:NSMakeRect(24,2,288,18) view:v];_connection.textColor=NSColor.secondaryLabelColor;
    [_light connect];if(_light.device)[_light send:0x24 bytes:NULL count:0];[self refresh];
    _timer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*t){[weak tick];}];[NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    NSNotificationCenter*center=NSWorkspace.sharedWorkspace.notificationCenter;
    [center addObserver:self selector:@selector(appActivated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [center addObserver:self selector:@selector(appLaunched:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
    [self applyCurrentRule];
    [center addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [center addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    NSMenu*menu=[NSMenu new];NSMenuItem*root=[NSMenuItem new];[menu addItem:root];NSMenu*submenu=[NSMenu new];[submenu addItemWithTitle:@"退出 Luma" action:@selector(terminate:) keyEquivalent:@"q"];root.submenu=submenu;NSApp.mainMenu=menu;
    NSArray*args=NSProcessInfo.processInfo.arguments;
    if(![args containsObject:@"--ui-test"])[self registerBrightnessShortcuts];
    if([args containsObject:@"--ui-test"]){[self runTests];return;}
    if([args containsObject:@"--show"]||[args containsObject:@"--capture-panel"]){if([args containsObject:@"--capture-panel"])_popover.behavior=NSPopoverBehaviorApplicationDefined;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self togglePopover:nil];});}
    if([args containsObject:@"--settings"]||[args containsObject:@"--capture-settings"])[self showSettings:nil];
    NSUInteger pageArg=[args indexOfObject:@"--settings-page"];if(pageArg!=NSNotFound&&pageArg+1<args.count){[self showSettings:nil];_tabs.selectedSegment=MAX(0,MIN(4,[args[pageArg+1]integerValue]));[self changeTab:_tabs];}
    if([args containsObject:@"--dark-settings"]){[self showSettings:nil];_settings.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];}
    if([args containsObject:@"--capture-detection"]){[self showSettings:nil];_tabs.selectedSegment=2;[self changeTab:_tabs];}
    if([args containsObject:@"--capture-shortcuts"]){[self showSettings:nil];_tabs.selectedSegment=4;[self changeTab:_tabs];}
    if([args containsObject:@"--diagnose"]){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{BOOL night;float strength;BOOL available=ReadNightShift(&night,&strength);printf("valid=%d power=%d brightness=%d kelvin=%d auto=%d video=%d presence=%d timeIndex=%d sensitivity=%d nightAvailable=%d\n",self.light.valid,self.light.power,self.light.brightness,self.light.kelvin,self.light.autoMode,self.light.videoMode,self.light.presenceEnabled,self.light.awayIndex,self.light.sensitivity,available);[NSApp terminate:nil];});}
    if([args containsObject:@"--capture-panel"]||[args containsObject:@"--capture-settings"]){BOOL settings=[args containsObject:@"--capture-settings"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{NSWindow*w=settings?self.settings:self.panelContent.window;NSString*file=[[NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent]stringByAppendingPathComponent:settings?@"settings-native.png":@"panel-native.png"];NSTask*task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/sbin/screencapture"];task.arguments=@[@"-x",@"-o",@"-l",[NSString stringWithFormat:@"%ld",(long)w.windowNumber],file];NSError*error=nil;if([task launchAndReturnError:&error]){[task waitUntilExit];printf("capture=%d window=%ld\n",task.terminationStatus,(long)w.windowNumber);}else NSLog(@"%@",error);[NSApp terminate:nil];});}
}
- (void)applyPending {if(_pendingPreset&&_light.valid&&!_busy){NSString*i=_pendingPreset;_pendingPreset=nil;[self applyPreset:FindPreset(_presets,i)];}}
- (BOOL)isDragging {return _brightness.dragging||_temperature.dragging||_sceneBrightness.dragging||_sceneTemperature.dragging;}
- (void)refresh {
    if(_pendingMode){BOOL actual=_pendingMode==7?_light.power:_pendingMode==9?_light.videoMode:_pendingMode==6?_light.presenceEnabled:_light.autoMode;if(actual==_pendingModeValue)_pendingMode=0;}
    _connection.stringValue=_light.valid?(_pendingMode?@"正在切换模式…":@""):(_light.message?:@"未连接");
    BOOL valid=_light.valid;for(NSButton*b in @[_powerButton?:[NSButton new],_autoButton?:[NSButton new],_videoButton?:[NSButton new],_presenceButton?:[NSButton new]])b.enabled=valid;
    if(_pendingMode==7)_powerButton.enabled=NO;if(_pendingMode==1||_pendingMode==4)_autoButton.enabled=NO;if(_pendingMode==9)_videoButton.enabled=NO;if(_pendingMode==6)_presenceButton.enabled=NO;
    _powerButton.contentTintColor=NSColor.blackColor;
    _autoButton.contentTintColor=_light.autoMode?NSColor.controlAccentColor:NSColor.secondaryLabelColor;_videoButton.contentTintColor=_light.videoMode?NSColor.controlAccentColor:NSColor.secondaryLabelColor;_presenceButton.contentTintColor=_light.presenceEnabled?NSColor.controlAccentColor:NSColor.secondaryLabelColor;
    ((CardButton*)_autoButton).active=valid&&_light.autoMode;((CardButton*)_videoButton).active=valid&&_light.videoMode;((CardButton*)_presenceButton).active=valid&&_light.presenceEnabled;
    _presenceSwitch.state=_light.presenceEnabled;_presenceSwitch.enabled=valid&&_pendingMode!=6;_awayPicker.enabled=valid&&_light.presenceKnown;_sensitivityPicker.enabled=valid&&_light.presenceKnown;
    if(_light.presenceKnown&&!_loading){[_awayPicker selectItemAtIndex:_light.awayIndex];_sensitivityPicker.selectedSegment=_light.sensitivity;}
    if(_shortcutPending&&(_light.brightness==_shortcutBrightness||NSDate.timeIntervalSinceReferenceDate-_shortcutLastUsed>2))_shortcutPending=NO;
    int displayedBrightness=_shortcutPending?_shortcutBrightness:_light.brightness;
    if(![self isDragging]){_brightness.enabled=valid;_temperature.enabled=valid;if(valid&&!_busy){_brightness.doubleValue=displayedBrightness;_temperature.doubleValue=(6500-_light.kelvin)/38.0;_brightnessLabel.stringValue=[NSString stringWithFormat:@"%d%%",displayedBrightness];_kelvinLabel.stringValue=[NSString stringWithFormat:@"%d K",_light.kelvin];}}
    for(NSUInteger i=0;i<_presetButtons.count;i++){NSDictionary*p=_presets[i];NSButton*b=_presetButtons[i];b.enabled=valid;((CardButton*)b).active=valid&&_light.power&&[p[@"brightness"]intValue]==_light.brightness&&[p[@"kelvin"]intValue]==_light.kelvin;b.contentTintColor=NSColor.labelColor;}
}
- (void)buildPresetButtons {
    for(NSButton*b in _presetButtons)[b removeFromSuperview];[_presetButtons removeAllObjects];NSUInteger count=MIN(4,_presets.count);CGFloat width=288.0/MAX(1,count);
    for(NSUInteger i=0;i<count;i++){NSDictionary*p=_presets[i];NSButton*b=[CardButton buttonWithTitle:p[@"name"] target:self action:@selector(selectPreset:)];b.frame=NSMakeRect(24+i*width,243,width-4,58);b.bordered=NO;((CardButton*)b).card=YES;b.image=SceneIcon(p[@"icon"],p[@"name"]);b.imagePosition=NSImageAbove;b.font=[NSFont systemFontOfSize:11];b.tag=i;b.toolTip=[NSString stringWithFormat:@"%@ · %@%% · %@ K",p[@"name"],p[@"brightness"],p[@"kelvin"]];[_panelContent addSubview:b];[_presetButtons addObject:b];}
}
- (void)allScenes:(id)sender {NSMenu*m=[NSMenu new];for(NSDictionary*p in _presets){NSMenuItem*i=[[NSMenuItem alloc]initWithTitle:p[@"name"] action:@selector(selectMenuPreset:) keyEquivalent:@""];i.target=self;i.representedObject=p[@"id"];i.image=[NSImage imageWithSystemSymbolName:p[@"icon"] accessibilityDescription:nil];[m addItem:i];}[m addItem:NSMenuItem.separatorItem];NSMenuItem*edit=[[NSMenuItem alloc]initWithTitle:@"编辑场景…" action:@selector(showSettings:) keyEquivalent:@""];edit.target=self;[m addItem:edit];[m popUpMenuPositioningItem:nil atLocation:NSMakePoint(210,304) inView:_panelContent];}
- (void)selectMenuPreset:(NSMenuItem*)item {[self manualInteraction];[self applyPreset:FindPreset(_presets,item.representedObject)];}
- (void)togglePopover:(id)sender {if(_popover.shown){[_popover close];return;}NSString*bundle=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;if(bundle&&![bundle isEqual:NSBundle.mainBundle.bundleIdentifier])_lastExternalBundle=bundle;[_light query];[NSApp activateIgnoringOtherApps:YES];[_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSRectEdgeMinY];}
- (void)manualInteraction {_shortcutPending=NO;_pendingMode=0;_softwareOff=NO;_softwareRestore=nil;_idleBaseline=NSDate.timeIntervalSinceReferenceDate;_cameraManaged=NO;_cameraRestore=nil;_pendingPreset=nil;}
- (void)finish:(NSUInteger)g {dispatch_after(dispatch_time(DISPATCH_TIME_NOW,180*NSEC_PER_MSEC),dispatch_get_main_queue(),^{if(g!=self.generation)return;self.busy=NO;[self.light query];[self refresh];});}
- (void)expectMode:(uint8_t)command value:(BOOL)value {
    _pendingMode=command;_pendingModeValue=value;_modeStarted=NSDate.timeIntervalSinceReferenceDate;NSTimeInterval start=_modeStarted;[self refresh];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(self.pendingMode&&self.modeStarted==start){self.pendingMode=0;[self.light query];[self refresh];}});
}
- (NSArray*)savedShortcuts {return [Settings() arrayForKey:@"brightnessShortcuts.v1"]?:@[@{@"key":@(kVK_F1),@"mods":@(kEventKeyModifierFnMask)},@{@"key":@(kVK_F2),@"mods":@(kEventKeyModifierFnMask)}];}
- (BOOL)installShortcuts:(NSArray*)bindings {
    [self stopBrightnessRepeat];
    if(!_hotKeyHandler){EventTypeSpec types[]={{kEventClassKeyboard,kEventHotKeyPressed},{kEventClassKeyboard,kEventHotKeyReleased}};
        OSStatus result=InstallEventHandler(GetApplicationEventTarget(),BrightnessHotKeyHandler,2,types,(__bridge void*)self,&_hotKeyHandler);
        if(result!=noErr){_hotKeyStatus=@"快捷键服务无法启动。";return NO;}}
    if(_dimHotKey){UnregisterEventHotKey(_dimHotKey);_dimHotKey=NULL;}if(_brightHotKey){UnregisterEventHotKey(_brightHotKey);_brightHotKey=NULL;}
    EventHotKeyID dim={0x69436872,1},bright={0x69436872,2};
    OSStatus lower=RegisterEventHotKey([bindings[0][@"key"]unsignedIntValue],[bindings[0][@"mods"]unsignedIntValue],dim,GetApplicationEventTarget(),0,&_dimHotKey);
    OSStatus upper=RegisterEventHotKey([bindings[1][@"key"]unsignedIntValue],[bindings[1][@"mods"]unsignedIntValue],bright,GetApplicationEventTarget(),0,&_brightHotKey);
    if(lower!=noErr||upper!=noErr){if(_dimHotKey){UnregisterEventHotKey(_dimHotKey);_dimHotKey=NULL;}if(_brightHotKey){UnregisterEventHotKey(_brightHotKey);_brightHotKey=NULL;}_hotKeyStatus=[NSString stringWithFormat:@"快捷键被占用或不可用（%d / %d）。",(int)lower,(int)upper];return NO;}
    _hotKeyStatus=@"亮度快捷键已生效，每次调整 5%。";return YES;
}
- (void)registerBrightnessShortcuts {[self installShortcuts:[self savedShortcuts]];}
- (NSArray*)shortcutFlags {return @[@(kEventKeyModifierFnMask),@(cmdKey),@(optionKey),@(controlKey),@(shiftKey)];}
- (void)loadShortcutControls:(NSArray*)bindings {
    for(NSUInteger row=0;row<2;row++){for(NSMenuItem*item in _shortcutKeys[row].itemArray)if([item.representedObject isEqual:bindings[row][@"key"]])[_shortcutKeys[row] selectItem:item];
        for(NSUInteger j=0;j<5;j++)_shortcutModifiers[row][j].state=([bindings[row][@"mods"]unsignedIntValue]&[[self shortcutFlags][j]unsignedIntValue])!=0;}
}
- (void)buildShortcuts:(NSView*)v {
    [self label:@"组合键" size:15 frame:NSMakeRect(0,324,612,28) view:v];
    [self label:@"选择按键及修饰键，点击保存后全局生效，每次调整 5%。" size:12 frame:NSMakeRect(0,288,612,24) view:v];
    NSArray*codes=@[@122,@120,@99,@118,@96,@97,@98,@100,@101,@109,@103,@111,@123,@124,@125,@126];
    NSArray*names=@[@"F1",@"F2",@"F3",@"F4",@"F5",@"F6",@"F7",@"F8",@"F9",@"F10",@"F11",@"F12",@"←",@"→",@"↓",@"↑"];
    NSMutableArray*keys=[NSMutableArray new],*modifiers=[NSMutableArray new];
    for(NSUInteger row=0;row<2;row++){CGFloat y=230-row*75;[self label:row?@"调亮":@"调暗" size:13 frame:NSMakeRect(0,y,60,26) view:v];
        NSPopUpButton*key=[self picker:NSMakeRect(66,y,95,28) items:names action:NULL view:v];for(NSUInteger i=0;i<codes.count;i++)key.itemArray[i].representedObject=codes[i];[keys addObject:key];
        NSMutableArray*checks=[NSMutableArray new];NSArray*labels=@[@"Fn",@"⌘",@"⌥",@"⌃",@"⇧"];for(NSUInteger j=0;j<5;j++)[checks addObject:[self check:labels[j] frame:NSMakeRect(184+j*80,y,76,26) action:NULL view:v]];[modifiers addObject:checks];}
    _shortcutKeys=keys;_shortcutModifiers=modifiers;[self loadShortcutControls:[self savedShortcuts]];
    [self button:@"保存快捷键" frame:NSMakeRect(0,90,132,30) action:@selector(saveShortcuts:) view:v];
    [self button:@"恢复默认" frame:NSMakeRect(146,90,118,30) action:@selector(resetShortcuts:) view:v];
    _shortcutStatus=[self label:_hotKeyStatus?:@"默认：Fn + F1 调暗，Fn + F2 调亮。" size:12 frame:NSMakeRect(0,20,612,58) view:v];_shortcutStatus.maximumNumberOfLines=3;
}
- (void)resetShortcuts:(id)sender {[self loadShortcutControls:@[@{@"key":@(kVK_F1),@"mods":@(kEventKeyModifierFnMask)},@{@"key":@(kVK_F2),@"mods":@(kEventKeyModifierFnMask)}]];_shortcutStatus.stringValue=@"已填入默认快捷键，点击保存后生效。";}
- (void)saveShortcuts:(id)sender {
    NSMutableArray*bindings=[NSMutableArray new];for(NSUInteger i=0;i<2;i++){UInt32 mods=0;for(NSUInteger j=0;j<5;j++)if(_shortcutModifiers[i][j].state)mods|=[[self shortcutFlags][j]unsignedIntValue];
        if(!mods){_shortcutStatus.stringValue=@"请至少选择一个修饰键，以免拦截普通按键。";return;}[bindings addObject:@{@"key":_shortcutKeys[i].selectedItem.representedObject,@"mods":@(mods)}];}
    if([bindings[0]isEqual:bindings[1]]){_shortcutStatus.stringValue=@"调暗和调亮不能使用相同的快捷键。";return;}
    NSArray*old=[self savedShortcuts];if([self installShortcuts:bindings]){[Settings() setObject:bindings forKey:@"brightnessShortcuts.v1"];_shortcutStatus.stringValue=@"已保存并立即生效，重启后仍会保留。";}
    else{NSString*error=_hotKeyStatus;BOOL restored=[self installShortcuts:old];_shortcutStatus.stringValue=[error stringByAppendingString:restored?@" 原快捷键已恢复，新设置未保存。":@" 新设置未保存；原快捷键也无法注册，请重新选择。"] ;}
}
- (void)stopBrightnessRepeat {[_brightnessRepeatTimer invalidate];_brightnessRepeatTimer=nil;_heldBrightnessKey=0;}
- (void)brightnessKey:(NSInteger)identifier pressed:(BOOL)pressed {
    if(!pressed){if(_heldBrightnessKey==identifier)[self stopBrightnessRepeat];return;}
    if(_heldBrightnessKey==identifier)return;
    [self stopBrightnessRepeat];if(!_light.valid||_sleeping)return;
    _heldBrightnessKey=identifier;NSInteger delta=identifier==1?-5:5;[self adjustBrightnessShortcut:delta];
    __weak App*weak=self;
    _brightnessRepeatTimer=[[NSTimer alloc]initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:.35] interval:.10 repeats:YES block:^(NSTimer*t){App*s=weak;if(!s||!s.light.valid||s.sleeping){[s stopBrightnessRepeat];[t invalidate];return;}[s adjustBrightnessShortcut:delta];}];
    [NSRunLoop.mainRunLoop addTimer:_brightnessRepeatTimer forMode:NSRunLoopCommonModes];
}
- (void)adjustBrightnessShortcut:(NSInteger)delta {
    if(!_light.valid||_sleeping)return;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    int base=_shortcutPending&&now-_shortcutLastUsed<2?_shortcutBrightness:_light.brightness;
    int value=MAX(0,MIN(100,base+(int)delta));
    if(value==base)return;
    [self manualInteraction];_shortcutBrightness=value;_shortcutPending=YES;_shortcutLastUsed=now;
    [self writeBrightness:value slider:nil];
    // Keep repeated presses based on the requested value while HID status catches up.
    _brightness.doubleValue=value;_brightnessLabel.stringValue=[NSString stringWithFormat:@"%d%%",value];
    if(delta>0&&!_light.power){NSUInteger g=_generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,65*NSEC_PER_MSEC),dispatch_get_main_queue(),^{if(g!=self.generation)return;uint8_t on=1;[self.light send:7 bytes:&on count:1];});}
}
- (void)togglePower:(id)sender {if(!_light.valid)return;[self manualInteraction];++_generation;_busy=NO;uint8_t value=!_light.power;if([_light send:7 bytes:&value count:1])[self expectMode:7 value:value];[self finish:_generation];}
- (void)toggleAuto:(id)sender {if(!_light.valid)return;[self manualInteraction];++_generation;_busy=NO;BOOL target=!_light.autoMode;if(!target){uint8_t b=_light.brightness;uint8_t data[]={b,b};if([_light send:4 bytes:data count:2])[self expectMode:4 value:NO];}else if([_light send:1 bytes:NULL count:0])[self expectMode:1 value:YES];[self finish:_generation];}
- (void)toggleVideo:(id)sender {if(!_light.valid)return;[self manualInteraction];++_generation;_busy=NO;uint8_t value=!_light.videoMode;if([_light send:9 bytes:&value count:1])[self expectMode:9 value:value];[self finish:_generation];}
- (void)togglePresence:(id)sender {if(!_light.valid)return;uint8_t value=sender==_presenceSwitch?_presenceSwitch.state:!_light.presenceEnabled;if([_light send:6 bytes:&value count:1])[self expectMode:6 value:value];[self finish:_generation];}
- (BOOL)writeAllowed:(LiveSlider*)slider {NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;if(slider.dragging&&now-_lastWrite<.06)return NO;_lastWrite=now;return YES;}
- (void)writeBrightness:(int)b slider:(LiveSlider*)slider {
    if(!_light.valid||![self writeAllowed:slider])return;++_generation;_busy=NO;uint8_t v=MAX(0,MIN(100,b)),bytes[]={v,v};[_light send:4 bytes:bytes count:2];if(!slider.dragging)[self finish:_generation];
}
- (void)writeKelvin:(int)k slider:(LiveSlider*)slider {
    if(!_light.valid||![self writeAllowed:slider])return;++_generation;_busy=NO;k=MAX(2700,MIN(6500,k));uint8_t bytes[]={k>>8,k&255,k>>8,k&255};[_light send:3 bytes:bytes count:4];if(!slider.dragging)[self finish:_generation];
}
- (void)rememberActiveValue:(NSNumber*)value key:(NSString*)key {
    if(!_activePresetID){for(NSDictionary*p in _presets)if([p[@"brightness"]intValue]==_light.brightness&&[p[@"kelvin"]intValue]==_light.kelvin){_activePresetID=p[@"id"];break;}}
    for(NSUInteger i=0;i<_presets.count;i++){NSDictionary*p=_presets[i];if(![p[@"id"]isEqual:_activePresetID])continue;
        NSMutableDictionary*updated=[p mutableCopy];updated[key]=value;_presets[i]=updated;[self saveConfiguration];
        if(_settings&&_selectedScene==(NSInteger)i){[self loadScene];}
        _settingsMessage.stringValue=@"";break;
    }
}
- (void)changeBrightness:(LiveSlider*)slider {[self manualInteraction];int b=(int)round(slider.doubleValue);_brightnessLabel.stringValue=[NSString stringWithFormat:@"%d%%",b];[self rememberActiveValue:@(b) key:@"brightness"];[self writeBrightness:b slider:slider];}
- (void)changeTemperature:(LiveSlider*)slider {[self manualInteraction];int k=MAX(2700,MIN(6500,(int)round((6500-slider.doubleValue*38)/25)*25));_kelvinLabel.stringValue=[NSString stringWithFormat:@"%d K",k];_nightBase=k;_nightManaged=NO;[self rememberActiveValue:@(k) key:@"kelvin"];[self writeKelvin:k slider:slider];}
- (void)selectPreset:(NSButton*)sender {[self manualInteraction];[self applyPreset:_presets[sender.tag]];}
- (void)sendSteps:(NSArray<NSDictionary*>*)steps index:(NSUInteger)index generation:(NSUInteger)g {
    if(g!=_generation)return;if(index>=steps.count){[self finish:g];return;}NSDictionary*step=steps[index];NSData*data=step[@"data"];
    if(![_light send:[step[@"command"]intValue] bytes:data.bytes count:data.length]){_busy=NO;[self refresh];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,65*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self sendSteps:steps index:index+1 generation:g];});
}
- (void)applyPreset:(NSDictionary*)preset {
    if(!preset)return;_activePresetID=preset[@"id"];if(!_light.valid){_pendingPreset=preset[@"id"];return;}
    int k=[preset[@"kelvin"]intValue];_nightBase=k;if([Settings() boolForKey:@"night.v3"]){BOOL active;float strength;if(ReadNightShift(&active,&strength)&&active){k=WarmKelvin(k,strength);_nightManaged=YES;_lastNight=YES;_lastNightStrength=strength;}}
    uint8_t temp[]={k>>8,k&255,k>>8,k&255},b=[preset[@"brightness"]intValue],brightness[]={b,b},on=1,off=0;
    NSMutableArray*steps=[NSMutableArray new];if(_light.videoMode)[steps addObject:@{@"command":@9,@"data":[NSData dataWithBytes:&off length:1]}];
    [steps addObjectsFromArray:@[@{@"command":@3,@"data":[NSData dataWithBytes:temp length:4]},@{@"command":@4,@"data":[NSData dataWithBytes:brightness length:2]},@{@"command":@7,@"data":[NSData dataWithBytes:&on length:1]}]];
    _busy=YES;[self sendSteps:steps index:0 generation:++_generation];
}
- (void)restoreState:(NSDictionary*)state {
    if(!state)return;NSUInteger g=++_generation;_busy=YES;int k=[state[@"kelvin"]intValue];uint8_t temp[]={k>>8,k&255,k>>8,k&255},b=[state[@"brightness"]intValue],brightness[]={b,b},power=[state[@"power"]boolValue],video=[state[@"video"]boolValue];
    NSMutableArray*steps=[@[@{@"command":@3,@"data":[NSData dataWithBytes:temp length:4]},@{@"command":@4,@"data":[NSData dataWithBytes:brightness length:2]},@{@"command":@9,@"data":[NSData dataWithBytes:&video length:1]},@{@"command":@7,@"data":[NSData dataWithBytes:&power length:1]}]mutableCopy];if([state[@"auto"]boolValue])[steps addObject:@{@"command":@1,@"data":NSData.data}];[self sendSteps:steps index:0 generation:g];
}
- (void)applyRuleForBundle:(NSString*)bundle {
    if(![Settings() boolForKey:@"automation.v2"]||_cameraManaged||_softwareOff)return;
    NSString*p=RulePreset(_rules,bundle);if(p){[self applyPreset:FindPreset(_presets,p)];_settingsMessage.stringValue=@"App 联动已触发。";}
}
- (void)appLaunched:(NSNotification*)notification {
    NSRunningApplication*a=notification.userInfo[NSWorkspaceApplicationKey];
    if(a.bundleIdentifier&&![a.bundleIdentifier isEqual:NSBundle.mainBundle.bundleIdentifier])[self applyRuleForBundle:a.bundleIdentifier];
}
- (void)appActivated:(NSNotification*)notification {NSRunningApplication*a=notification.userInfo[NSWorkspaceApplicationKey];if(!a.bundleIdentifier||[a.bundleIdentifier isEqual:NSBundle.mainBundle.bundleIdentifier])return;_lastExternalBundle=a.bundleIdentifier;_pendingPreset=nil;[self applyCurrentRule];}
- (void)applyCurrentRule {[self applyRuleForBundle:_lastExternalBundle];}
- (void)toggleAutomation:(NSButton*)sender {[Settings() setBool:sender.state==NSControlStateValueOn forKey:@"automation.v2"];_pendingPreset=nil;if(sender.state)[self applyCurrentRule];}
- (void)tick {
    NSString*front=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    if(front&&![front isEqual:NSBundle.mainBundle.bundleIdentifier]&&![front isEqual:_lastExternalBundle]){_lastExternalBundle=front;[self applyCurrentRule];}
    if(_sleeping)return;if(!_light.device&&![_light isKindOfClass:FakeLight.class]){[_light connect];if(_light.device)[_light send:0x24 bytes:NULL count:0];}
    else if(!_busy&&![self isDragging]&&(_popover.shown||_settings.visible||_rules.count||[Settings() integerForKey:@"idleSeconds.v3"]))[_light query];
    if(!_light.valid||[self isDragging])return;
    [self processIdle:CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,kCGAnyInputEventType) now:NSDate.timeIntervalSinceReferenceDate];
    if(_softwareOff||_busy)return;
    if([Settings() boolForKey:@"camera.v3"]){
        BOOL active=NO;AVCaptureDeviceDiscoverySession*discovery=[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,AVCaptureDeviceTypeExternalUnknown] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];for(AVCaptureDevice*d in discovery.devices)if(d.inUseByAnotherApplication){active=YES;break;}
        [self processCamera:active];
    }
    if(!_cameraManaged)[self syncNight:NO];
}
- (void)processIdle:(double)idle now:(NSTimeInterval)now {
    NSInteger seconds=[Settings() integerForKey:@"idleSeconds.v3"];if(!seconds||_sleeping)return;
    idle=MIN(idle,MAX(0,now-_idleBaseline));
    if(!_softwareOff&&_light.power&&idle>=seconds){_softwareRestore=LightState(_light);uint8_t off=0;++_generation;_busy=NO;if([_light send:7 bytes:&off count:1])_softwareOff=YES;}
    else if(_softwareOff&&idle<2){NSDictionary*state=_softwareRestore;_softwareOff=NO;_softwareRestore=nil;_idleBaseline=now;[self restoreState:state];}
}
- (void)processCamera:(BOOL)active {
    if(active==_lastCamera)return;_lastCamera=active;
    if(active){_cameraRestore=LightState(_light);_cameraManaged=YES;uint8_t on=1;++_generation;_busy=NO;[_light send:9 bytes:&on count:1];[self finish:_generation];}
    else if(_cameraManaged){NSDictionary*state=_cameraRestore;_cameraManaged=NO;_cameraRestore=nil;[self restoreState:state];}
}
- (void)syncNight:(BOOL)force {
    if(![Settings() boolForKey:@"night.v3"]||_softwareOff||_cameraManaged||_busy)return;BOOL active;float strength;if(!ReadNightShift(&active,&strength))return;
    if(!force&&active==_lastNight&&fabs(strength-_lastNightStrength)<.02)return;
    if(active&&!_nightManaged){_nightBase=_light.kelvin;_nightManaged=YES;}
    if(_nightManaged){int k=active?WarmKelvin(_nightBase,strength):_nightBase;[self writeKelvin:k slider:nil];if(!active)_nightManaged=NO;}
    _lastNight=active;_lastNightStrength=strength;
}
- (void)willSleep:(NSNotification*)notification {[self stopBrightnessRepeat];_sleeping=YES;_pendingPreset=nil;if([Settings() boolForKey:@"sleep.v3"]&&_light.valid){uint8_t off=0;[_light send:7 bytes:&off count:1];}}
- (void)didWake:(NSNotification*)notification {_sleeping=NO;_idleBaseline=NSDate.timeIntervalSinceReferenceDate;_softwareOff=NO;_pendingWake=[Settings() boolForKey:@"wake.v3"];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,700*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self.light connect];});}
- (NSTableView*)table:(NSRect)frame columns:(NSArray*)columns view:(NSView*)parent {
    NSScrollView*scroll=[[NSScrollView alloc]initWithFrame:frame];scroll.hasVerticalScroller=YES;scroll.borderType=NSNoBorder;scroll.drawsBackground=NO;scroll.wantsLayer=YES;scroll.layer.cornerRadius=12;scroll.autohidesScrollers=YES;
    NSTableView*table=[[NSTableView alloc]initWithFrame:scroll.bounds];table.headerView=nil;table.backgroundColor=NSColor.clearColor;table.style=NSTableViewStyleFullWidth;table.focusRingType=NSFocusRingTypeNone;table.rowHeight=40;table.dataSource=self;table.delegate=self;table.allowsEmptySelection=NO;
    for(NSString*identifier in columns){NSTableColumn*c=[[NSTableColumn alloc]initWithIdentifier:identifier];c.width=[identifier isEqual:@"preset"]?230:(frame.size.width-4)/columns.count;[table addTableColumn:c];}
    table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;scroll.documentView=table;[parent addSubview:scroll];return table;
}
- (void)showSettings:(id)sender {
    NSString*bundle=NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;if(bundle&&![bundle isEqual:NSBundle.mainBundle.bundleIdentifier])_lastExternalBundle=bundle;
    [_popover close];if(_settings){[_settings makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];return;}
    _loading=YES;
    _settings=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,900,560) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskFullSizeContentView backing:NSBackingStoreBuffered defer:NO];_settings.title=@"Luma 设置";_settings.releasedWhenClosed=NO;
    _settings.titlebarAppearsTransparent=YES;_settings.titleVisibility=NSWindowTitleHidden;_settings.movableByWindowBackground=YES;
    NSView*v=_settings.contentView;
    NSVisualEffectView*background=[[NSVisualEffectView alloc]initWithFrame:v.bounds];background.material=NSVisualEffectMaterialWindowBackground;background.blendingMode=NSVisualEffectBlendingModeBehindWindow;background.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[v addSubview:background];
    NSView*navContent=[[NSView alloc]initWithFrame:NSMakeRect(0,0,194,490)];
    if(@available(macOS 26.0,*)){
        NSGlassEffectView*glass=[[NSGlassEffectView alloc]initWithFrame:NSMakeRect(16,22,194,490)];glass.cornerRadius=22;glass.style=NSGlassEffectViewStyleRegular;glass.contentView=navContent;[v addSubview:glass];
    }else{
        NSVisualEffectView*glass=[[NSVisualEffectView alloc]initWithFrame:NSMakeRect(16,22,194,490)];glass.material=NSVisualEffectMaterialSidebar;glass.wantsLayer=YES;glass.layer.cornerRadius=22;glass.layer.masksToBounds=YES;[glass addSubview:navContent];[v addSubview:glass];
    }
    NSTextField*brand=[self label:@"Luma" size:20 frame:NSMakeRect(20,440,160,30) view:navContent];brand.font=[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    [self label:@"Light, beautifully controlled." size:10 frame:NSMakeRect(20,423,166,20) view:navContent].textColor=NSColor.secondaryLabelColor;
    [self label:@"Designed by Chenxi" size:10 frame:NSMakeRect(20,18,166,20) view:navContent].textColor=NSColor.secondaryLabelColor;
    NSArray*titles=@[@"模式中心",@"App 联动",@"入离席侦测",@"系统联动",@"快捷键"];
    NSArray*symbols=@[@"slider.horizontal.3",@"app.connected.to.app.below.fill",@"figure.walk",@"desktopcomputer",@"keyboard"];
    _tabs=[NSSegmentedControl segmentedControlWithLabels:titles trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];_tabs.selectedSegment=0;
    NSMutableArray*navigation=[NSMutableArray new];
    for(NSUInteger i=0;i<titles.count;i++){NSButton*b=[SettingsNavigationButton buttonWithTitle:titles[i] target:self action:@selector(navigateSettings:)];b.frame=NSMakeRect(12,371.3-i*54,170,42);b.tag=i;b.bezelStyle=NSBezelStyleRounded;b.image=[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:titles[i]];b.imagePosition=NSImageLeading;b.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];b.imageHugsTitle=YES;b.toolTip=titles[i];[navContent addSubview:b];[navigation addObject:b];}_settingsNavigation=navigation;

    _settingsHeading=[self label:@"模式中心" size:25 frame:NSMakeRect(240,470,624,36) view:v];_settingsHeading.font=[NSFont systemFontOfSize:25 weight:NSFontWeightSemibold];
    _settingsSubtitle=[self label:@"为不同场景调整光线。" size:12 frame:NSMakeRect(240,443,624,24) view:v];_settingsSubtitle.textColor=NSColor.secondaryLabelColor;
    NSView*rightContent=[[NSView alloc]initWithFrame:NSMakeRect(228,58,648,379)];[v addSubview:rightContent];
    NSMutableArray*panes=[NSMutableArray new];for(int i=0;i<5;i++){NSView*p=[[NSView alloc]initWithFrame:NSMakeRect(18,8,612,363)];p.hidden=i!=0;[rightContent addSubview:p];[panes addObject:p];}_panes=panes;
    [self buildScenes:panes[0]];[self buildRules:panes[1]];[self buildDetection:panes[2]];[self buildSystem:panes[3]];[self buildShortcuts:panes[4]];
    for(NSTextField*f in @[_nameField,_brightnessField,_kelvinField]){f.focusRingType=NSFocusRingTypeNone;f.bezelStyle=NSTextFieldRoundedBezel;f.font=[NSFont systemFontOfSize:13];}
    _brightnessField.alignment=NSTextAlignmentRight;_kelvinField.alignment=NSTextAlignmentRight;
    _settingsMessage=[self label:@"" size:11 frame:NSMakeRect(240,24,624,22) view:v];_settingsMessage.textColor=NSColor.secondaryLabelColor;
    for(NSView*pane in _panes)[self styleSettingsControls:pane];
    [self changeTab:_tabs];
    [_sceneTable reloadData];[_sceneTable selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(_selectedScene,(NSInteger)_presets.count-1)] byExtendingSelection:NO];[self loadScene];[_ruleTable reloadData];_loading=NO;[self refresh];[_settings center];[_settings makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)styleSettingsControls:(NSView*)view {
    if([view isKindOfClass:NSControl.class]){NSControl*c=(NSControl*)view;c.focusRingType=NSFocusRingTypeNone;}
    if(@available(macOS 26.0,*)){if([view isKindOfClass:NSButton.class]&&![view isKindOfClass:NeutralCheck.class]){NSButton*b=(NSButton*)view;b.bezelStyle=NSBezelStyleGlass;}}
    if([view isKindOfClass:CardButton.class]){((CardButton*)view).settingsAction=YES;((NSButton*)view).bordered=NO;}
    for(NSView*child in view.subviews)[self styleSettingsControls:child];
}
- (void)navigateSettings:(NSButton*)sender {[_settings makeFirstResponder:nil];_tabs.selectedSegment=sender.tag;[self changeTab:_tabs];}
- (void)changeTab:(id)sender {
    NSInteger selected=_tabs.selectedSegment;
    NSArray*titles=@[@"模式中心",@"App 联动",@"入离席侦测",@"系统联动",@"亮度快捷键"];
    NSArray*details=@[@"为不同场景调整光线。",@"启动或切换应用，让灯光跟随当前任务。",@"分别设置人体侦测与键鼠空闲熄灯。",@"让灯光响应 Mac 的唤醒、相机和 Night Shift。",@"分别设置调暗与调亮组合键，保存后立即生效。"];
    for(NSUInteger i=0;i<_panes.count;i++){_panes[i].hidden=(NSInteger)i!=selected;NSButton*b=_settingsNavigation[i];b.bezelColor=nil;b.contentTintColor=(NSInteger)i==selected?NSColor.blackColor:NSColor.labelColor;b.state=(NSInteger)i==selected?NSControlStateValueOn:NSControlStateValueOff;b.needsDisplay=YES;}
    _settingsHeading.stringValue=titles[selected];_settingsSubtitle.stringValue=details[selected];_settingsMessage.stringValue=@"";[self refresh];
}
- (void)doneSettings:(id)sender {[_settings makeFirstResponder:nil];[_settings close];}
- (void)buildScenes:(NSView*)v {
    SceneListFrame*listFrame=[[SceneListFrame alloc]initWithFrame:NSMakeRect(-8,-4,196,367)];[v addSubview:listFrame];
    _sceneTable=[self table:NSMakeRect(0,42,180,312) columns:@[@"scene"] view:v];
    [self button:@"＋" frame:NSMakeRect(0,4,42,28) action:@selector(addScene:) view:v];[self button:@"−" frame:NSMakeRect(44,4,42,28) action:@selector(deleteScene:) view:v];[self button:@"复制" frame:NSMakeRect(90,4,88,28) action:@selector(copyScene:) view:v];
    [self label:@"场景名称" size:12 frame:NSMakeRect(204,322,110,24) view:v];_nameField=[self field:NSMakeRect(302,318,300,32) view:v];
    [self label:@"场景图标" size:12 frame:NSMakeRect(204,278,110,24) view:v];_iconPicker=[self picker:NSMakeRect(302,274,300,32) items:@[@"电脑",@"阅读",@"咖啡",@"月亮",@"太阳",@"游戏",@"电影",@"灯泡"] action:@selector(iconChanged:) view:v];for(NSUInteger i=0;i<_icons.count;i++)[_iconPicker itemAtIndex:i].image=[NSImage imageWithSystemSymbolName:_icons[i] accessibilityDescription:nil];
    [self label:@"亮度" size:12 frame:NSMakeRect(204,231,100,18) view:v];_brightnessField=[self field:NSMakeRect(516,228,64,24) view:v];[self label:@"%" size:12 frame:NSMakeRect(586,231,20,18) view:v];_sceneBrightness=[self slider:NO frame:NSMakeRect(204,188,398,34) action:@selector(sceneBrightnessChanged:) view:v];
    [self label:@"色温" size:12 frame:NSMakeRect(204,135,100,18) view:v];_kelvinField=[self field:NSMakeRect(506,132,74,24) view:v];[self label:@"K" size:12 frame:NSMakeRect(586,135,20,18) view:v];_sceneTemperature=[self slider:YES frame:NSMakeRect(204,92,398,34) action:@selector(sceneTemperatureChanged:) view:v];
    NSButton*preview=[self check:@"选择场景时立即预览灯光" frame:NSMakeRect(204,42,398,26) action:@selector(previewChanged:) view:v];preview.state=[Settings() boolForKey:@"previewSelection.v3"];
}
- (void)buildRules:(NSView*)v {
    SceneListFrame*listBackground=[[SceneListFrame alloc]initWithFrame:NSMakeRect(-8,32,628,288)];[v addSubview:listBackground];
    [self label:@"启动或切换到 App 时应用指定场景" size:15 frame:NSMakeRect(0,326,440,28) view:v];_automationSwitch=[self check:@"启用联动" frame:NSMakeRect(478,326,134,28) action:@selector(toggleAutomation:) view:v];_automationSwitch.state=[Settings() boolForKey:@"automation.v2"];
    _ruleTable=[self table:NSMakeRect(0,88,612,224) columns:@[@"app",@"preset"] view:v];_ruleTable.allowsEmptySelection=YES;[_ruleTable deselectAll:nil];_ruleTable.tableColumns[0].width=344;_ruleTable.tableColumns[1].width=248;
    [self button:@"添加 App…" frame:NSMakeRect(0,40,130,30) action:@selector(chooseApp:) view:v];[self button:@"删除" frame:NSMakeRect(140,40,86,30) action:@selector(deleteRule:) view:v];
}
- (void)buildDetection:(NSView*)v {
    _presenceSwitch=[self check:@"启用挂灯的入离席侦测" frame:NSMakeRect(0,322,600,30) action:@selector(togglePresence:) view:v];
    [self label:@"离席熄灯时间" size:13 frame:NSMakeRect(0,264,200,26) view:v];_awayPicker=[self picker:NSMakeRect(300,264,302,28) items:@[@"3 分钟",@"5 分钟",@"10 分钟"] action:@selector(presenceParamsChanged:) view:v];
    [self label:@"侦测灵敏度" size:13 frame:NSMakeRect(0,212,200,26) view:v];_sensitivityPicker=[NSSegmentedControl segmentedControlWithLabels:@[@"低",@"中",@"高"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(presenceParamsChanged:)];_sensitivityPicker.selectedSegmentBezelColor=NSColor.blackColor;_sensitivityPicker.focusRingType=NSFocusRingTypeNone;_sensitivityPicker.frame=NSMakeRect(300,212,302,28);[v addSubview:_sensitivityPicker];
    NSBox*line=[[NSBox alloc]initWithFrame:NSMakeRect(0,180,612,1)];line.boxType=NSBoxSeparator;[v addSubview:line];
    [self label:@"键鼠空闲熄灯时间" size:15 frame:NSMakeRect(0,137,300,28) view:v];
    _idlePicker=[self picker:NSMakeRect(300,137,302,28) items:@[@"关闭",@"5 秒",@"10 秒",@"15 秒",@"30 秒",@"45 秒",@"1 分钟",@"90 秒",@"2 分钟",@"3 分钟",@"5 分钟",@"10 分钟",@"15 分钟",@"30 分钟"] action:@selector(idleChanged:) view:v];NSArray*seconds=@[@0,@5,@10,@15,@30,@45,@60,@90,@120,@180,@300,@600,@900,@1800];NSUInteger i=[seconds indexOfObject:@([Settings() integerForKey:@"idleSeconds.v3"])];[_idlePicker selectItemAtIndex:i==NSNotFound?0:i];
    NSTextField*hint=[self label:@"键鼠空闲辅助：按键盘、鼠标的空闲时间熄灯，恢复操作后亮灯。\n它与上方的真实人体侦测独立，不会把键鼠空闲当成人已离席。" size:12 frame:NSMakeRect(0,66,612,56) view:v];hint.lineBreakMode=NSLineBreakByWordWrapping;hint.maximumNumberOfLines=3;hint.textColor=NSColor.secondaryLabelColor;
    [self label:@"原版硬件协议仅提供 3 / 5 / 10 分钟档位。" size:11 frame:NSMakeRect(0,20,612,28) view:v].textColor=NSColor.secondaryLabelColor;
}
- (void)buildSystem:(NSView*)v {
    _wakeSwitch=[self check:@"Mac 唤醒时自动开灯" frame:NSMakeRect(0,322,612,28) action:@selector(systemChanged:) view:v];_wakeSwitch.state=[Settings() boolForKey:@"wake.v3"];
    _sleepSwitch=[self check:@"Mac 睡眠时关灯" frame:NSMakeRect(0,274,612,28) action:@selector(systemChanged:) view:v];_sleepSwitch.state=[Settings() boolForKey:@"sleep.v3"];
    _cameraSwitch=[self check:@"相机使用时自动切换视频模式" frame:NSMakeRect(0,226,612,28) action:@selector(systemChanged:) view:v];_cameraSwitch.state=[Settings() boolForKey:@"camera.v3"];
    [self label:@"相机停止使用后恢复先前灯光；不启动或录制相机。" size:11 frame:NSMakeRect(24,198,588,24) view:v].textColor=NSColor.secondaryLabelColor;
    _nightSwitch=[self check:@"跟随 Night Shift 调整挂灯色温" frame:NSMakeRect(0,142,612,28) action:@selector(systemChanged:) view:v];_nightSwitch.state=[Settings() boolForKey:@"night.v3"];
    BOOL enabled;float strength;BOOL available=ReadNightShift(&enabled,&strength);_nightSwitch.enabled=available;
    [self label:available?@"Night Shift 开启时按系统暖色强度调整，关闭后恢复原色温。":@"当前系统无法读取 Night Shift 状态。" size:11 frame:NSMakeRect(24,114,588,24) view:v].textColor=NSColor.secondaryLabelColor;
    [self label:@"亮度组合键可在「快捷键」页修改。" size:11 frame:NSMakeRect(0,83,612,26) view:v].textColor=NSColor.secondaryLabelColor;
    _systemStatus=[self label:@"自动化优先级：空闲熄灯 → 相机视频模式 → App 场景 → Night Shift。" size:11 frame:NSMakeRect(0,42,612,40) view:v];_systemStatus.maximumNumberOfLines=2;_systemStatus.textColor=NSColor.secondaryLabelColor;
}
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {return [NeutralRow new];}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {return table==_sceneTable?_presets.count:_rules.count;}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    if(table==_ruleTable&&[column.identifier isEqual:@"preset"]){NSDictionary*r=_rules[row];NSPopUpButton*p=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(5,6,column.width-12,28) pullsDown:NO];for(NSDictionary*scene in _presets){[p addItemWithTitle:scene[@"name"]];p.lastItem.representedObject=scene[@"id"];if([scene[@"id"]isEqual:r[@"preset"]])[p selectItem:p.lastItem];}p.identifier=r[@"bundle"];p.target=self;p.action=@selector(rulePresetChanged:);p.focusRingType=NSFocusRingTypeNone;if(@available(macOS 26.0,*))p.bezelStyle=NSBezelStyleGlass;
        NSView*container=[[NSView alloc]initWithFrame:NSMakeRect(0,0,column.width,40)];p.translatesAutoresizingMaskIntoConstraints=NO;[container addSubview:p];[NSLayoutConstraint activateConstraints:@[[p.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],[p.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],[p.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],[p.heightAnchor constraintEqualToConstant:28]]];return container;}
    NSTableCellView*cell=[[NSTableCellView alloc]initWithFrame:NSMakeRect(0,0,column.width,40)];NSDictionary*item=table==_sceneTable?_presets[row]:_rules[row];
    NSImageView*image=[[NSImageView alloc]initWithFrame:NSMakeRect(12,10,20,20)];image.image=table==_sceneTable?[NSImage imageWithSystemSymbolName:item[@"icon"] accessibilityDescription:nil]:[NSWorkspace.sharedWorkspace iconForFile:[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:item[@"bundle"]].path?:@""];cell.imageView=image;[cell addSubview:image];
    NSTextField*label=[self label:item[@"name"] size:12 frame:NSMakeRect(42,12,column.width-54,16) view:cell];label.lineBreakMode=NSLineBreakByTruncatingTail;cell.textField=label;
    image.translatesAutoresizingMaskIntoConstraints=NO;label.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[[image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:12],[image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],[image.widthAnchor constraintEqualToConstant:20],[image.heightAnchor constraintEqualToConstant:20],[label.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:10],[label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],[label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
    if(row==table.selectedRow){label.textColor=NSColor.blackColor;image.contentTintColor=NSColor.blackColor;}return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    if(notification.object!=_sceneTable||_loading||_sceneTable.selectedRow<0)return;_selectedScene=_sceneTable.selectedRow;[self loadScene];if([Settings() boolForKey:@"previewSelection.v3"]){[self manualInteraction];[self applyPreset:_presets[_selectedScene]];}
}
- (void)loadScene {
    if(_selectedScene<0||(NSUInteger)_selectedScene>=_presets.count)return;BOOL loading=_loading;_loading=YES;NSDictionary*p=_presets[_selectedScene];_nameField.stringValue=p[@"name"];_brightnessField.stringValue=[p[@"brightness"]stringValue];_kelvinField.stringValue=[p[@"kelvin"]stringValue];_sceneBrightness.doubleValue=[p[@"brightness"]doubleValue];_sceneTemperature.doubleValue=(6500-[p[@"kelvin"]doubleValue])/38.0;
    NSUInteger icon=[_icons indexOfObject:p[@"icon"]];[_iconPicker selectItemAtIndex:icon==NSNotFound?0:icon];_loading=loading;
}
- (void)saveConfiguration {[Settings() setObject:_presets forKey:@"presets.v2"];[Settings() setObject:_rules forKey:@"rules.v2"];[self buildPresetButtons];[self refresh];}
- (void)reloadSceneList {
    BOOL loading=_loading;_loading=YES;[_sceneTable reloadData];if(_presets.count)[_sceneTable selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(_selectedScene,(NSInteger)_presets.count-1)] byExtendingSelection:NO];[_ruleTable reloadData];_loading=loading;
}
- (BOOL)commitScene:(BOOL)preview {
    if(_loading||_selectedScene<0||(NSUInteger)_selectedScene>=_presets.count)return NO;
    NSString*name=[_nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];int b,k;NSScanner*bs=[NSScanner scannerWithString:_brightnessField.stringValue],*ks=[NSScanner scannerWithString:_kelvinField.stringValue];
    if(!name.length||name.length>16||![bs scanInt:&b]||!bs.isAtEnd||![ks scanInt:&k]||!ks.isAtEnd||b<0||b>100||k<2700||k>6500){_settingsMessage.stringValue=@"名称 1–16 字，亮度 0–100，色温 2700–6500 K。";return NO;}
    k=(int)round(k/25.0)*25;_presets[_selectedScene]=@{@"id":_presets[_selectedScene][@"id"],@"name":name,@"icon":_icons[MAX(0,_iconPicker.indexOfSelectedItem)],@"brightness":@(b),@"kelvin":@(k)};
    [self saveConfiguration];[self reloadSceneList];_sceneBrightness.doubleValue=b;_sceneTemperature.doubleValue=(6500-k)/38.0;
    _settingsMessage.stringValue=@"";
    if(preview){[self manualInteraction];[self applyPreset:_presets[_selectedScene]];}return YES;
}
- (void)controlTextDidBeginEditing:(NSNotification*)notification {
    NSTextField*field=notification.object;NSTextView*editor=(NSTextView*)field.currentEditor;
    editor.selectedTextAttributes=@{NSBackgroundColorAttributeName:NSColor.blackColor,NSForegroundColorAttributeName:NSColor.whiteColor};editor.insertionPointColor=NSColor.labelColor;
}
- (void)controlTextDidChange:(NSNotification*)notification {
    if(_loading)return;
    NSTextField*field=notification.object;
    if(field!=_nameField&&field!=_brightnessField&&field!=_kelvinField)return;
    NSTextView*editor=(NSTextView*)field.currentEditor;
    if(editor.hasMarkedText)return;
    ++_editGeneration;
    [self commitScene:field==_brightnessField||field==_kelvinField];
}
- (void)controlTextDidEndEditing:(NSNotification*)notification {if(_loading)return;++_editGeneration;[self commitScene:notification.object==_brightnessField||notification.object==_kelvinField];}
- (void)iconChanged:(id)sender {[self commitScene:NO];}
- (void)previewChanged:(NSButton*)sender {[Settings() setBool:sender.state==NSControlStateValueOn forKey:@"previewSelection.v3"];}
- (void)sceneBrightnessChanged:(LiveSlider*)slider {_activePresetID=_presets[_selectedScene][@"id"];_brightnessField.intValue=(int)round(slider.doubleValue);[self commitScene:NO];[self manualInteraction];[self writeBrightness:_brightnessField.intValue slider:slider];}
- (void)sceneTemperatureChanged:(LiveSlider*)slider {_activePresetID=_presets[_selectedScene][@"id"];int k=MAX(2700,MIN(6500,(int)round((6500-slider.doubleValue*38)/25)*25));_kelvinField.stringValue=[NSString stringWithFormat:@"%d",k];[self commitScene:NO];[self manualInteraction];[self writeKelvin:k slider:slider];}
- (void)addScene:(id)sender {int b=_light.valid?_light.brightness:50,k=_light.valid?_light.kelvin:4000;[_presets addObject:@{@"id":NSUUID.UUID.UUIDString,@"name":@"新场景",@"icon":@"lightbulb",@"brightness":@(b),@"kelvin":@(k)}];_selectedScene=_presets.count-1;[self saveConfiguration];[self reloadSceneList];[self loadScene];}
- (void)copyScene:(id)sender {if(_selectedScene<0)return;NSMutableDictionary*copy=[_presets[_selectedScene]mutableCopy];copy[@"id"]=NSUUID.UUID.UUIDString;copy[@"name"]=[NSString stringWithFormat:@"%@副本",copy[@"name"]];if([copy[@"name"]length]>16)copy[@"name"]=[copy[@"name"]substringToIndex:16];[_presets addObject:copy];_selectedScene=_presets.count-1;[self saveConfiguration];[self reloadSceneList];[self loadScene];}
- (BOOL)confirm:(NSString*)message {
    if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"])return YES;
    NSAlert*alert=[NSAlert new];alert.messageText=message;[alert addButtonWithTitle:@"删除"];[alert addButtonWithTitle:@"取消"];return [alert runModal]==NSAlertFirstButtonReturn;
}
- (void)deleteScene:(id)sender {
    if(_presets.count<=1){_settingsMessage.stringValue=@"至少保留一个场景。";return;}if(_selectedScene<0||![self confirm:@"删除此场景及引用它的 App 联动？"])return;
    NSString*identifier=_presets[_selectedScene][@"id"];NSIndexSet*linked=[_rules indexesOfObjectsPassingTest:^BOOL(NSDictionary*r,NSUInteger i,BOOL*stop){return [r[@"preset"]isEqual:identifier];}];[_rules removeObjectsAtIndexes:linked];[_presets removeObjectAtIndex:_selectedScene];_selectedScene=MIN(_selectedScene,(NSInteger)_presets.count-1);[self saveConfiguration];[self reloadSceneList];[self loadScene];
}
- (void)chooseApp:(id)sender {
    NSOpenPanel*p=NSOpenPanel.openPanel;p.canChooseDirectories=NO;p.canChooseFiles=YES;p.allowedContentTypes=@[UTTypeApplicationBundle];p.directoryURL=[NSURL fileURLWithPath:@"/Applications"];p.prompt=@"添加";
    [p beginSheetModalForWindow:_settings completionHandler:^(NSModalResponse response){if(response!=NSModalResponseOK)return;NSBundle*b=[NSBundle bundleWithURL:p.URL];if(!b.bundleIdentifier){self.settingsMessage.stringValue=@"这个 App 没有有效的标识。";return;}
        for(NSDictionary*r in self.rules)if([r[@"bundle"]isEqual:b.bundleIdentifier]){self.settingsMessage.stringValue=@"此 App 已绑定，可直接修改右侧场景。";return;}
        [self.rules addObject:@{@"bundle":b.bundleIdentifier,@"name":[NSFileManager.defaultManager displayNameAtPath:p.URL.path],@"preset":self.presets[MAX(0,self.selectedScene)][@"id"]}];[Settings() setBool:YES forKey:@"automation.v2"];self.automationSwitch.state=NSControlStateValueOn;[self saveConfiguration];[self.ruleTable reloadData];[self applyCurrentRule];self.settingsMessage.stringValue=@"绑定已保存，App 联动已启用。";
    }];
}
- (void)rulePresetChanged:(NSPopUpButton*)sender {
    for(NSUInteger i=0;i<_rules.count;i++)if([_rules[i][@"bundle"]isEqual:sender.identifier]){NSMutableDictionary*r=[_rules[i]mutableCopy];r[@"preset"]=sender.selectedItem.representedObject;_rules[i]=r;break;}[self saveConfiguration];[self applyCurrentRule];_settingsMessage.stringValue=@"绑定已保存并立即生效。";
}
- (void)deleteRule:(id)sender {NSInteger i=_ruleTable.selectedRow;if(i<0||![self confirm:@"删除此 App 绑定？"])return;[_rules removeObjectAtIndex:i];[self saveConfiguration];[_ruleTable reloadData];}
- (void)presenceParamsChanged:(id)sender {
    if(!_light.valid||!_light.presenceKnown)return;uint8_t bytes[]={MAX(0,_awayPicker.indexOfSelectedItem),MAX(0,_sensitivityPicker.selectedSegment)};
    [_light send:0x23 bytes:bytes count:2];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self.light send:0x24 bytes:NULL count:0];});_settingsMessage.stringValue=@"已发送，正在读取挂灯设置…";
}
- (void)idleChanged:(id)sender {NSArray*seconds=@[@0,@5,@10,@15,@30,@45,@60,@90,@120,@180,@300,@600,@900,@1800];[Settings() setInteger:[seconds[_idlePicker.indexOfSelectedItem]integerValue] forKey:@"idleSeconds.v3"];if(_softwareOff){NSDictionary*restore=_softwareRestore;_softwareOff=NO;_softwareRestore=nil;[self restoreState:restore];}_idleBaseline=NSDate.timeIntervalSinceReferenceDate;_settingsMessage.stringValue=@"空闲计时已更新，从现在重新计时。";}
- (void)systemChanged:(NSButton*)sender {
    NSString*key=sender==_wakeSwitch?@"wake.v3":sender==_sleepSwitch?@"sleep.v3":sender==_cameraSwitch?@"camera.v3":@"night.v3";[Settings() setBool:sender.state==NSControlStateValueOn forKey:key];
    if(sender==_cameraSwitch){if(!sender.state&&_cameraManaged){NSDictionary*state=_cameraRestore;_cameraManaged=NO;_cameraRestore=nil;[self restoreState:state];}_lastCamera=NO;}
    if(sender==_nightSwitch){if(!sender.state&&_nightManaged){int k=_nightBase;_nightManaged=NO;[self writeKelvin:k slider:nil];}else if(sender.state)[self syncNight:YES];}
    _settingsMessage.stringValue=@"已保存并生效。";
}
- (void)applicationWillTerminate:(NSNotification*)notification {[self stopBrightnessRepeat];if(_dimHotKey)UnregisterEventHotKey(_dimHotKey);if(_brightHotKey)UnregisterEventHotKey(_brightHotKey);if(_hotKeyHandler)RemoveEventHandler(_hotKeyHandler);[_timer invalidate];[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];[_light disconnect];}
- (void)runTests {
    [_timer invalidate];[self showSettings:nil];
    NSCAssert(self.shortcutKeys.count==2&&self.shortcutModifiers.count==2,@"shortcut editor controls");
    [self loadShortcutControls:@[@{@"key":@122,@"mods":@(cmdKey|optionKey)},@{@"key":@122,@"mods":@(cmdKey|optionKey)}]];
    [self saveShortcuts:nil];NSCAssert([self.shortcutStatus.stringValue containsString:@"不能"],@"duplicate shortcuts rejected");
    [self.shortcutKeys[1] selectItemAtIndex:1];[self saveShortcuts:nil];
    NSCAssert([self.shortcutStatus.stringValue containsString:@"已保存"],@"custom shortcut registration succeeds");
    NSCAssert([[[self savedShortcuts][0]objectForKey:@"mods"]unsignedIntValue]==(cmdKey|optionKey),@"shortcut configuration persists");
    NSCAssert(self.panelContent.subviews.count>10,@"panel content");for(NSView*v in self.panelContent.subviews)NSCAssert(![v isKindOfClass:NSClassFromString(@"NSGlassEffectView")],@"no nested glass");
    NSCAssert(NSEqualSizes(self.brightness.frame.size,self.temperature.frame.size),@"same slider geometry");
    [self addScene:nil];self.nameField.stringValue=@"测试场景";self.brightnessField.stringValue=@"73";self.kelvinField.stringValue=@"5024";NSCAssert([self commitScene:NO],@"scene commit");NSDictionary*scene=self.presets.lastObject;
    self.nameField.stringValue=@"即时保存";[self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:self.nameField]];
    NSCAssert([[[Settings() arrayForKey:@"presets.v2"]lastObject][@"name"]isEqual:@"即时保存"],@"text saves without ending editing");
    self.sceneBrightness.dragging=YES;self.sceneBrightness.doubleValue=61;[self sceneBrightnessChanged:self.sceneBrightness];
    NSCAssert([[[Settings() arrayForKey:@"presets.v2"]lastObject][@"brightness"]intValue]==61,@"slider saves during drag");
    self.sceneBrightness.dragging=NO;self.sceneBrightness.doubleValue=73;[self sceneBrightnessChanged:self.sceneBrightness];
    NSCAssert([scene[@"kelvin"]intValue]==5025,@"quantization");self.brightnessField.stringValue=@"999";NSCAssert(![self commitScene:NO],@"invalid brightness rejected");[self loadScene];
    [self.rules addObject:@{@"bundle":@"test.foreground",@"name":@"测试 App",@"preset":scene[@"id"]}];[self saveConfiguration];self.lastExternalBundle=@"test.foreground";
    self.automationSwitch.state=NSControlStateValueOn;[self toggleAutomation:self.automationSwitch];
    self.lastExternalBundle=@"unbound.app";[self applyRuleForBundle:@"test.foreground"];
    NSCAssert(![self.lastExternalBundle isEqual:@"test.foreground"],@"launch rule independent of foreground");
    NSCAssert(self.idlePicker.numberOfItems==14,@"expanded idle times");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        NSCAssert(self.light.brightness==73&&self.light.kelvin==5025,@"enable automation applies current app immediately");
        [Settings() setInteger:15 forKey:@"idleSeconds.v3"];self.idleBaseline=0;[self processIdle:16 now:100];NSCAssert(self.softwareOff&&!self.light.power,@"short idle powers off");[self processIdle:0 now:101];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            NSCAssert(self.light.power&&self.light.brightness==73,@"activity restores state");
            [self processCamera:YES];NSCAssert(self.light.videoMode&&self.cameraManaged,@"camera uses video mode");[self processCamera:NO];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                NSCAssert(!self.light.videoMode,@"camera restores earlier mode");
                [self.awayPicker selectItemAtIndex:1];self.sensitivityPicker.selectedSegment=0;[self presenceParamsChanged:nil];
                NSCAssert(self.light.awayIndex==1&&self.light.sensitivity==0,@"hardware presence parameters");
                self.sceneBrightness.doubleValue=46;[self sceneBrightnessChanged:self.sceneBrightness];NSCAssert(self.light.brightness==46&&[self.presets.lastObject[@"brightness"]intValue]==46,@"editor synchronizes hardware and persistence");
                NSWindow*w=self.sceneBrightness.window;NSPoint downPoint=[self.sceneBrightness convertPoint:NSMakePoint(12,17) toView:nil],upPoint=[self.sceneBrightness convertPoint:NSMakePoint(12+.75*(self.sceneBrightness.bounds.size.width-24),17) toView:nil];
                NSEvent*up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:upPoint modifierFlags:0 timestamp:1 windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0];
                NSEvent*down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:downPoint modifierFlags:0 timestamp:0 windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
                [NSApp postEvent:up atStart:YES];[self.sceneBrightness mouseDown:down];NSCAssert(self.light.brightness==75&&[self.presets.lastObject[@"brightness"]intValue]==75,@"real mouse tracking commits final value");
                NSPoint cdown=[self.sceneTemperature convertPoint:NSMakePoint(12,17) toView:nil],cup=[self.sceneTemperature convertPoint:NSMakePoint(12+.8*(self.sceneTemperature.bounds.size.width-24),17) toView:nil];
                NSEvent*cu=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:cup modifierFlags:0 timestamp:3 windowNumber:w.windowNumber context:nil eventNumber:3 clickCount:1 pressure:0];
                NSEvent*cd=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:cdown modifierFlags:0 timestamp:2 windowNumber:w.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
                [NSApp postEvent:cu atStart:YES];[self.sceneTemperature mouseDown:cd];
                NSCAssert([self.presets.lastObject[@"kelvin"]intValue]==3450,@"real settings color drag persists");
                NSInteger edited=self.selectedScene;
                [self.sceneTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                [self.sceneTable selectRowIndexes:[NSIndexSet indexSetWithIndex:edited] byExtendingSelection:NO];
                NSCAssert(self.kelvinField.intValue==3450,@"settings selection retains color");
                FakeLight*fake=(FakeLight*)self.light;fake.delayBrightness=YES;self.shortcutPending=NO;
                [self adjustBrightnessShortcut:5];[self adjustBrightnessShortcut:5];NSCAssert(self.shortcutBrightness==85&&self.light.brightness==75,@"rapid shortcuts accumulate despite stale device status");
                self.shortcutBrightness=98;[self adjustBrightnessShortcut:5];NSCAssert(self.shortcutBrightness==100,@"upper shortcut limit");
                self.shortcutBrightness=2;[self adjustBrightnessShortcut:-5];NSCAssert(self.shortcutBrightness==0,@"lower shortcut limit");
                fake.delayBrightness=NO;[self manualInteraction];NSCAssert(!self.shortcutPending,@"manual adjustment clears pending shortcut target");
                [self deleteScene:nil];NSCAssert(self.rules.count==0,@"scene deletion cleans rules");
                [self applyPreset:FindPreset(self.presets,@"focus")];
                self.temperature.doubleValue=(6500-4200)/38.0;[self changeTemperature:self.temperature];
                NSCAssert([FindPreset([Settings() arrayForKey:@"presets.v2"],@"focus")[@"kelvin"]intValue]==4200,@"panel changes saved to focus");
                [self applyPreset:FindPreset(self.presets,@"relax")];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                    [self applyPreset:FindPreset(self.presets,@"focus")];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                        NSCAssert(self.light.kelvin==4200,@"focus relax focus preserves edited kelvin");
                        [Settings() removePersistentDomainForName:@"local.barlight.testing"];
                        puts("PASS: edit focus, switch to relax, return to focus retains 4200 K");
                        self.light.brightness=50;self.shortcutPending=NO;[self brightnessKey:2 pressed:YES];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,650*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                            NSCAssert(self.light.brightness>=65,@"held key repeats");[self brightnessKey:2 pressed:NO];int stopped=self.light.brightness;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{NSCAssert(self.light.brightness==stopped&&!self.brightnessRepeatTimer,@"release stops repeating");puts("PASS: held brightness key repeats and release stops");[NSApp terminate:nil];});
                        });
                    });
                });
                puts("PASS: panel hierarchy; shared slider geometry; scene editing/validation; immediate app binding; short idle restore; camera restore; presence params; live editor synchronization; mouse tracking; shortcut accumulation and limits");
            });
        });
    });
}
@end
int main(int argc,const char**argv){@autoreleasepool{
    if(argc>1&&!strcmp(argv[1],"--selftest")){
        NSArray*p=DefaultPresets();NSCAssert(FindPreset(p,@"read")!=nil,@"lookup");NSArray*r=@[@{@"bundle":@"test",@"preset":@"focus"}];NSCAssert([RulePreset(r,@"test")isEqual:@"focus"],@"rule");NSCAssert(!RulePreset(r,@"other"),@"no match");NSCAssert(WarmKelvin(4500,1)==2700&&WarmKelvin(4500,0)==4500,@"night shift endpoints");puts("PASS: preset lookup, app matching, Night Shift temperature mapping");return 0;
    }
    NSApplication*app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];App*delegate=[App new];app.delegate=delegate;[app run];}return 0;}
