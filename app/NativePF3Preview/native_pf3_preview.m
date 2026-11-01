// Offline Canon RAW developer. Only system-installed PSE libraries are loaded.
// Arm64 ABI verified against the installed DppCore 1.32.20 exports.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>

typedef uint32_t U;
typedef void *Ref;
typedef struct { int32_t x,y,width,height; } DppRect;
typedef struct { int32_t width,height; } DppSize;
// The installed arm64 DppGetImageInfo writes four 32-bit fields; only the
// first two are needed for the developed image's actual source dimensions.
typedef struct { uint32_t width,height,reserved[2]; } DppImageInfo;
static U (*Init)(void),(*Term)(void),(*Release)(Ref);
static U (*CreateFile)(CFURLRef,U,U,Ref*),(*CreateServer)(Ref,Ref*),(*Revert)(Ref);
static U (*Set)(Ref,U,U,U,const void*),(*SetStyle)(Ref,CFURLRef),(*SetProfile)(Ref,Ref);
static U (*GetSize)(Ref,U,U,U*,U*),(*Get)(Ref,U,U,U,void*);
static U (*ProcessEx)(Ref,U,U,U,DppRect,DppSize,Ref,Ref*);
static U (*ProcessWith)(Ref,Ref,U,U,DppRect,DppSize,Ref,Ref*);
static U (*ImageInfo)(Ref,DppImageInfo*);
static U (*Memory)(void*,U,Ref*),(*Output)(Ref,U,U,Ref);

static void emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); fflush(stdout);
}
static BOOL check(U rc,NSString *name) { emit(@{@"event":name,@"rc":@(rc)});return rc==0; }
static NSString *sha(NSData *data) {
    unsigned char bytes[32]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *result=[NSMutableString new];
    for(int i=0;i<32;i++)[result appendFormat:@"%02x",bytes[i]];return result;
}
static NSString *fileHash(NSString *path) {
    NSInputStream *stream=[NSInputStream inputStreamWithFileAtPath:path];[stream open];
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);uint8_t bytes[65536];NSInteger count;
    while((count=[stream read:bytes maxLength:sizeof(bytes)])>0)CC_SHA256_Update(&ctx,bytes,(CC_LONG)count);
    [stream close];if(count<0)return nil;
    unsigned char digest[32];CC_SHA256_Final(digest,&ctx);NSMutableString *result=[NSMutableString new];
    for(int i=0;i<32;i++)[result appendFormat:@"%02x",digest[i]];return result;
}
static BOOL setU(Ref recipe,U prop,U value) {return check(Set(recipe,prop,0,4,&value),[NSString stringWithFormat:@"set-%08x",prop]);}
static BOOL setD(Ref recipe,U prop,double value) {return check(Set(recipe,prop,0,8,&value),[NSString stringWithFormat:@"set-%08x",prop]);}
static BOOL verifyD(Ref recipe,U prop,double expected,NSString *name) {
    double actual=NAN;U rc=Get(recipe,prop,0,8,&actual);
    emit(@{@"event":@"verified_recipe",@"name":name,@"expected":@(expected),@"actual":isfinite(actual)?@(actual):[NSNull null],@"rc":@(rc)});
    return rc==0&&actual==expected;
}
static NSData *render(Ref recipe,int w,int h,BOOL swapsAxes) {
    // Development uses sensor geometry; the output stage applies orientation.
    int developW=swapsAxes?h:w,developH=swapsAxes?w:h;
    DppRect developRect={0,0,developW,developH};DppSize developSize={developW,developH};
    DppSize outputSize={w,h};Ref base=NULL,result=NULL,stream=NULL;
    unsigned char aux[256]={0};NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)w*h*3];
    BOOL ok=check(ProcessEx(recipe,1,1,1,developRect,developSize,aux,&base),@"process_base")&&base;
    if(ok) {
        DppImageInfo info={0};
        ok=check(ImageInfo(base,&info),@"base_image_info")&&info.width>0&&info.height>0&&info.width<=100000&&info.height<=100000;
        // DPP may develop to a size different from the requested preview.
        // ProcessWith's rectangle is a SOURCE region, not the output size.
        // Reusing w/h here cropped a 1336x2004 portrait source to 1067x1600.
        DppRect full={0,0,swapsAxes?(int)info.height:(int)info.width,swapsAxes?(int)info.width:(int)info.height};
        if(ok) {
            emit(@{@"event":@"full_frame_geometry",@"baseWidth":@(info.width),@"baseHeight":@(info.height),@"sourceRegionWidth":@(full.width),@"sourceRegionHeight":@(full.height),@"outputWidth":@(w),@"outputHeight":@(h)});
            ok=check(ProcessWith(recipe,base,0,0,full,outputSize,aux,&result),@"process_output")&&result;
        }
    }
    if(ok)ok=check(Memory(data.mutableBytes,(U)data.length,&stream),@"memory_output")&&stream;
    if(ok)ok=check(Output(result,0x0d,w*3,stream),@"output_bgr24");
    if(stream)Release(stream);if(result)Release(result);if(base)Release(base);if(!ok)return nil;
    unsigned char *p=data.mutableBytes;for(NSUInteger i=0;i<data.length;i+=3){unsigned char t=p[i];p[i]=p[i+2];p[i+2]=t;}return data;
}
static int run(int argc,const char **argv) {
    NSString *photo=[NSString stringWithUTF8String:argv[1]],*out=[NSString stringWithUTF8String:argv[2]],*label=[NSString stringWithUTF8String:argv[3]];
    NSString *pf3=argc==7?[NSString stringWithUTF8String:argv[4]]:nil;
    if(!photo.isAbsolutePath||!out.isAbsolutePath||[[NSFileManager defaultManager]fileExistsAtPath:out])return 2;
    NSString *photoHash=fileHash(photo),*pf3Hash=pf3?fileHash(pf3):nil;if(!photoHash||(pf3&&!pf3Hash))return 2;
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:photo],NULL);
    if(!source)return 2;
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));CFRelease(source);
    int sourceW=[properties[(__bridge NSString*)kCGImagePropertyPixelWidth] intValue],sourceH=[properties[(__bridge NSString*)kCGImagePropertyPixelHeight] intValue];
    int orientation=[properties[(__bridge NSString*)kCGImagePropertyOrientation] intValue];if(!orientation)orientation=1;
    if(sourceW<1||sourceH<1||orientation<1||orientation>8)return 2;
    // DppCore renders the captured orientation. Use the corresponding display aspect.
    int displayW=orientation>=5?sourceH:sourceW,displayH=orientation>=5?sourceW:sourceH;
    double scale=MIN(1.0,1600.0/MAX(displayW,displayH));int w=MAX(1,(int)llround(displayW*scale)),h=MAX(1,(int)llround(displayH*scale));
    Ref file=NULL,recipe=NULL,profileStream=NULL;NSData *profileData=nil;int status=1;
    @try {
        if(!check(CreateFile((__bridge CFURLRef)[NSURL fileURLWithPath:photo],2,0,&file),@"open_photo")||!file)return 1;
        if(!check(CreateServer(file,&recipe),@"create_recipe")||!recipe)return 1;
        if(!check(Revert(recipe),@"revert_captured"))return 1;
        if(!setD(recipe,0x20001,0)||!setU(recipe,0x20101,255)||!setU(recipe,0x10200,1))return 1;
        if(pf3) {
            profileData=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[5]]];
            NSData *settingsData=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[6]]];
            NSDictionary *binding=settingsData?[NSJSONSerialization JSONObjectWithData:settingsData options:0 error:nil]:nil;
            NSDictionary *settings=binding[@"settings"];
            if(![binding[@"sourceSha256"] isEqual:pf3Hash]||![binding[@"iccSha256"] isEqual:sha(profileData)]||![settings isKindOfClass:NSDictionary.class])return 1;
            if(profileData.length<128||memcmp((const char*)profileData.bytes+36,"acsp",4))return 1;
            U base=[binding[@"baseStyle"] unsignedIntValue];
            if(![@[@0x81,@0x82,@0x83,@0x84,@0x85,@0x88] containsObject:@(base)])return 1;
            if(!check(SetStyle(recipe,(__bridge CFURLRef)[NSURL fileURLWithPath:pf3]),@"apply_native_pf3"))return 1;
            if(!check(Memory((void*)profileData.bytes,(U)profileData.length,&profileStream),@"icc_memory")||!profileStream)return 1;
            if(!check(SetProfile(recipe,profileStream),@"apply_pse_generated_icc"))return 1;
            U actualBase=0;U rc=Get(recipe,0x1ff52c,0,4,&actualBase);
            emit(@{@"event":@"verified_base",@"expected":@(base),@"actual":@(actualBase),@"rc":@(rc)});if(rc||base!=actualBase)return 1;
            for(NSArray *entry in @[@[@"contrast",@0x20303],@[@"colorTone",@0x20304],@[@"saturation",@0x20305],@[@"sharpness",@0x20308],@[@"fineness",@0x20309],@[@"threshold",@0x2030a]]) {
                NSNumber *value=settings[entry[0]];U prop=[entry[1] unsignedIntValue];
                if(![value isKindOfClass:NSNumber.class]||!setD(recipe,prop,value.doubleValue)||!verifyD(recipe,prop,value.doubleValue,entry[0]))return 1;
            }
        } else {
            if(!setU(recipe,0x20301,0x84))return 1;
            for(NSArray *entry in @[@[@0x20303,@0],@[@0x20304,@0],@[@0x20305,@0],@[@0x20308,@2],@[@0x20309,@2],@[@0x2030a,@3]])if(!setD(recipe,[entry[0] unsignedIntValue],[entry[1] doubleValue]))return 1;
        }
        U wb=0;U wbRC=Get(recipe,0x20101,0,4,&wb);
        emit(@{@"event":@"verified_recipe",@"name":@"whiteBalance",@"expected":@255,@"actual":@(wb),@"rc":@(wbRC)});
        if(wbRC||wb!=255||!verifyD(recipe,0x20001,0,@"exposureEV"))return 1;
        double warmScale=MIN(1.0,480.0/MAX(w,h));if(!render(recipe,MAX(1,(int)llround(w*warmScale)),MAX(1,(int)llround(h*warmScale)),orientation>=5))return 1;
        NSData *rgb=render(recipe,w,h,orientation>=5);if(!rgb)return 1;
        const unsigned char *p=rgb.bytes;unsigned char lo=255,hi=0;for(NSUInteger i=0;i<rgb.length;i++){lo=MIN(lo,p[i]);hi=MAX(hi,p[i]);}
        // A uniform photograph can be legitimate; reject only an empty buffer.
        if(rgb.length!=(NSUInteger)w*h*3)return 1;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)rgb);
        CGImageRef image=CGImageCreate(w,h,8,24,w*3,space,(CGBitmapInfo)kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
        CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:out],CFSTR("public.png"),1,NULL);
        BOOL saved=NO;if(image&&dest){CGImageDestinationAddImage(dest,image,NULL);saved=CGImageDestinationFinalize(dest);}
        if(dest)CFRelease(dest);if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);if(!saved)return 1;
        BOOL unchanged=[photoHash isEqual:fileHash(photo)]&&(!pf3||[pf3Hash isEqual:fileHash(pf3)]);
        emit(@{@"event":@"render_complete",@"label":label,@"photoSha256":photoHash,@"pf3Sha256":pf3Hash?:[NSNull null],@"width":@(w),@"height":@(h),@"sourceWidth":@(sourceW),@"sourceHeight":@(sourceH),@"orientation":@(orientation),@"pixelMin":@(lo),@"pixelMax":@(hi),@"rgbSha256":sha(rgb),@"originalsUnchanged":@(unchanged),@"cameraAccess":@NO});status=unchanged?0:1;
    } @catch(NSException *error) {emit(@{@"event":@"exception",@"message":error.reason?:@""});}
    @finally {if(profileStream)Release(profileStream);if(recipe)Release(recipe);if(file)Release(file);}
    return status;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=4&&argc!=7){fprintf(stderr,"usage: native_pf3_preview PHOTO PNG LABEL [PF3 ICC SETTINGS-JSON]\n");return 2;}
    NSString *path=@"/Applications/Canon Utilities/Picture Style Editor/PictureStyleEditor.app/Contents/PlugIns/DppCore.bundle";
    NSBundle *bundle=[NSBundle bundleWithPath:path];NSError *error=nil;
    if(![bundle loadAndReturnError:&error]){fprintf(stderr,"Canon PSE DppCore load failed: %s\n",error.description.UTF8String);return 2;}
    void *module=dlopen(bundle.executablePath.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);if(!module)return 2;
#define BIND(pointer,name) do{pointer=dlsym(module,name);if(!pointer){fprintf(stderr,"missing %s\n",name);return 2;}}while(0)
    BIND(Init,"DppInitializeSDK");BIND(Term,"DppTerminateSDK");BIND(Release,"DppRelease");BIND(CreateFile,"DppCreateFileStream");BIND(CreateServer,"DppCreateImageServer");BIND(Revert,"DppRevertRecipeToCaptured");
    BIND(Set,"DppSetPropertyData");BIND(Get,"DppGetPropertyData");BIND(GetSize,"DppGetPropertySize");BIND(SetStyle,"DppSetPictureStyleFile");BIND(SetProfile,"DppSetPictureStyleUserProfile");
    BIND(ProcessEx,"DppProcessImageEx");BIND(ProcessWith,"DppProcessImageWithImageEx");BIND(ImageInfo,"DppGetImageInfo");BIND(Memory,"DppCreateMemoryStreamFromPointer");BIND(Output,"DppOutputImageToStream");
    [NSApplication sharedApplication];if(!check(Init(),@"initialize"))_exit(1);
    int status=run(argc,argv);if(!check(Term(),@"terminate"))status=1;
    // Vendor ObjC plugin autorelease teardown can crash after successful Term.
    // Nothing is left open; process isolation makes cancellation deterministic.
    fflush(stdout);fflush(stderr);_exit(status);
}}
