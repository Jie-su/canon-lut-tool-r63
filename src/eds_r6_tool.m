// R6 Mark III snapshot and explicit full33 installer for the pinned local SDK.
// Installation uses EdsSetPropertyData(203), then (115), for selected initialized
// slots. Only a public203 rc9 permits the pinned CEdsObject dispatcher fallback.
// A 0x9189 retrieval, never a cached getter alone, confirms state.
// Getter-format backups are evidence, NOT full33 restore carriers.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef uint32_t U;
typedef void *Ref;
static U (*Init)(void), (*Term)(void), (*List)(Ref *), (*Count)(Ref,U *);
static U (*Child)(Ref,int,Ref *), (*Open)(Ref), (*Close)(Ref), (*Release)(Ref);
static U (*PropSize)(Ref,U,int,U *,U *), (*Get)(Ref,U,int,U,void *);
static U (*Set)(Ref,U,int,U,const void *);
static U (*NativeSet)(Ref,U,int,U,const void *);
static U (*NativeSize)(Ref,U,int,U *,U *), (*NativeGet)(Ref,U,int,U,void *);
static U (*FreshStyle)(Ref,int), (*Extend)(Ref,int);
static void *module;
static FILE *auditFile;
static NSString *const SDKHash = @"35a425fc84460bac539eb051b921362c142dfcde966514b18249be8c393529ea";
static NSString *const ParserHash = @"f4f2f931c174bfb200fde98d26c0e35c6bcaa3cf2374dbf89583bbeb7fe866b5";
static NSString *const DescriptorHash = @"eeaec0b23cc8b0a168fa6f9ba6c80a0431528b80ce05b52cfb168686442d84ac";
static const U StyleProperty = 0x01000203;
static const NSUInteger Full33Length = 431616;
static NSString *sha(NSData *data) {
    if (!data) return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *s = [NSMutableString string];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [s appendFormat:@"%02x",digest[i]];
    return s;
}
static void emit(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
    if (!data) return;
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout); fflush(stdout);
    if (auditFile) { fwrite(data.bytes,1,data.length,auditFile); fputc('\n',auditFile); fflush(auditFile); fsync(fileno(auditFile)); }
}
static BOOL save(NSData *data,NSString *path) {
    if (!data) return NO;
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL,0600);
    if (fd<0) return NO;
    NSUInteger written=0; BOOL ok=YES;
    while (written<data.length) {
        ssize_t n=write(fd,(const unsigned char *)data.bytes+written,data.length-written);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) { ok=NO; break; }
        written+=(NSUInteger)n;
    }
    if (ok && fsync(fd)) ok=NO;
    if (close(fd)) ok=NO;
    return ok;
}
static BOOL jsonSave(id object,NSString *path) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:NULL];
    return data && save(data,path);
}
static BOOL newDirectory(NSString *path) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    return [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:NULL];
}
static BOOL syncDirectory(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY);
    if (fd<0) return NO;
    BOOL ok=fsync(fd)==0; if (close(fd)) ok=NO; return ok;
}
static NSString *name(U property,int parameter) {
    return [NSString stringWithFormat:@"property-%08x-param-%d.bin",property,parameter];
}
static U word(NSData *data,NSUInteger offset) {
    U n=0; if (offset+4<=data.length) memcpy(&n,(const unsigned char *)data.bytes+offset,4); return n;
}
static BOOL hex(NSString *s) {
    return [s isKindOfClass:NSString.class] && s.length==64 &&
        [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static NSData *hexBytes(id value,NSUInteger length) {
    if (![value isKindOfClass:NSString.class] || [value length]!=length*2) return nil;
    const char *text=[value UTF8String]; NSMutableData *data=[NSMutableData dataWithLength:length];
    unsigned char *out=data.mutableBytes;
    for (NSUInteger i=0;i<length;i++) {
        unsigned char byte=0;
        for (NSUInteger j=0;j<2;j++) {
            char c=text[i*2+j]; unsigned char n;
            if (c>='0' && c<='9') n=(unsigned char)(c-'0');
            else if (c>='a' && c<='f') n=(unsigned char)(c-'a'+10);
            else return nil;
            byte=(unsigned char)((byte<<4)|n);
        }
        out[i]=byte;
    }
    return data;
}
static NSData *boundFile(id path,id digest) {
    if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath] || !hex(digest)) return nil;
    NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue]>16*1024*1024) return nil;
    NSData *data=[NSData dataWithContentsOfFile:path];
    return [sha(data) isEqual:digest] ? data : nil;
}
static BOOL envelope(NSData *data,NSUInteger length) {
    return data.length==length && word(data,0)==1 && word(data,4)==length-40 && word(data,40)==length-40;
}
static NSString *title(NSData *data) {
    if (data.length<78) return nil;
    const unsigned char *p=data.bytes; NSUInteger end=46;
    while (end<78 && p[end]) { if (p[end]<0x20 || p[end]>0x7e) return nil; end++; }
    if (end==46 || end==78) return nil;
    for (NSUInteger i=end;i<78;i++) if (p[i]) return nil;
    return [[NSString alloc] initWithBytes:p+46 length:end-46 encoding:NSASCIIStringEncoding];
}
static BOOL full33(NSData *data) {
    if (!envelope(data,Full33Length) || !title(data)) return NO;
    const unsigned char *p=data.bytes;
    if (memcmp(p+8,p+46,32) || word(data,96)!=0xdeadbeef || word(data,100)!=0xdeadbeef) return NO;
    for (NSUInteger i=372;i<Full33Length;i+=2) { uint16_t n=0; memcpy(&n,p+i,2); if (n>32768) return NO; }
    return YES;
}
static BOOL knownReadback(NSData *data) {
    return (envelope(data,83076) || envelope(data,Full33Length)) && title(data)!=nil;
}
static BOOL metadataMatches(NSData *input,NSData *readback) {
    if (input.length<372 || !knownReadback(readback)) return NO;
    const unsigned char *a=input.bytes,*b=readback.bytes;
    // Desktop caption is discarded during transmission. Both envelope sizes
    // change when R6 III returns the extended17 representation.
    for (NSUInteger i=0;i<372;i++) {
        if (i>=4 && i<44) continue;
        if (a[i]!=b[i]) return NO;
    }
    return YES;
}
static BOOL sameSnapshotValue(NSData *a,NSData *b,U property) {
    if (!a || !b || a.length!=b.length) return NO;
    if (property!=StyleProperty || a.length!=83076) return [a isEqualToData:b];
    // Only 24 documented unused auxiliary words can vary between fresh reads.
    BOOL used[1024]={0}; NSUInteger count=0;
    for (NSUInteger blue=0;blue<10;blue++) for (NSUInteger green=0;green<10;green++) for (NSUInteger red=0;red<10;red++) {
        NSUInteger n=5*((green%5)+5*(blue%5))+(blue>4?513:0)+(green>4?257:0)+red+(red>4?124:0);
        if (n>=1024 || used[n]) return NO; used[n]=YES; count++;
    }
    if (count!=1000) return NO;
    const unsigned char *x=a.bytes,*y=b.bytes;
    for (NSUInteger i=0;i<a.length;i++) {
        if (i>=78980 && !used[(i-78980)/4]) continue;
        if (x[i]!=y[i]) return NO;
    }
    return YES;
}
static NSDictionary *colorFingerprint(NSData *data) {
    if (!knownReadback(data)) return @{@"representation":@"empty-or-unknown",@"bytes":@(data.length)};
    NSMutableArray *tables=[NSMutableArray array]; NSMutableData *active=[NSMutableData data];
    NSUInteger tableLength=data.length==83076?19652:215622;
    NSUInteger count=data.length==83076?4:2;
    for (NSUInteger table=0;table<count;table++) {
        NSUInteger offset=372+table*tableLength;
        NSData *body=[data subdataWithRange:NSMakeRange(offset,tableLength)]; [active appendData:body];
        [tables addObject:@{@"offset":@(offset),@"bytes":@(tableLength),@"sha256":sha(body)}];
    }
    NSMutableDictionary *answer=[@{@"representation":data.length==83076?@"extended17":@"full33",@"tables":tables} mutableCopy];
    if (data.length==83076) {
        NSMutableData *aux=[NSMutableData data];
        for (NSUInteger blue=0;blue<10;blue++) for (NSUInteger green=0;green<10;green++) for (NSUInteger red=0;red<10;red++) {
            NSUInteger n=5*((green%5)+5*(blue%5))+(blue>4?513:0)+(green>4?257:0)+red+(red>4?124:0);
            [aux appendBytes:(const unsigned char *)data.bytes+78980+n*4 length:4];
        }
        answer[@"activeAuxiliaryNodes"]=@1000; answer[@"activeAuxiliarySha256"]=sha(aux); [active appendData:aux];
    }
    answer[@"activeColorSha256"]=sha(active); return answer;
}
static BOOL modelMetadata(NSDictionary *values) {
    NSData *model=values[name(0x01000001,0)],*fw=values[name(7,0)],*desc=values[name(0x01000210,0)];
    NSMutableData *expected=[NSMutableData dataWithLength:32]; memcpy(expected.mutableBytes,"1.1.2",5);
    return model.length==4 && word(model,0)==0x80000518 && [fw isEqual:expected]
        && desc.length==15076 && [sha(desc) isEqual:DescriptorHash]
        && [values[name(0x114,0)] length]==4 && [values[name(0x115,0)] length]==32;
}
static BOOL symbol(void *out,const char *s,BOOL required) {
    void *address=dlsym(module,s);
    if (!address) { emit(@{@"event":@"missing_symbol",@"symbol":@(s),@"required":@(required)}); return !required; }
    memcpy(out,&address,sizeof(address)); return YES;
}
static NSData *readProperty(Ref camera,U property,int parameter) {
    BOOL state=property==0x114 || property==0x115;
    if ((property==StyleProperty && (parameter<33 || parameter>35)) ||
        (state && parameter!=0 && (parameter<33 || parameter>35)) ||
        (!state && property!=StyleProperty && parameter!=0)) return nil;
    U type=0,length=0; BOOL native=NO;
    U rc=PropSize(camera,property,parameter,&type,&length);
    if (rc==9 && (property==0x01000001 || property==0x01000210 || property==StyleProperty)) {
        native=YES; rc=NativeSize(camera,property,parameter,&type,&length);
    }
    if (rc || !length || length>1048576) {
        emit(@{@"event":@"property_size_error",@"property":@(property),@"parameter":@(parameter),@"rc":@(rc),@"bytes":@(length)}); return nil;
    }
    NSMutableData *data=[NSMutableData dataWithLength:length];
    rc=(native?NativeGet:Get)(camera,property,parameter,length,data.mutableBytes);
    emit(@{@"event":@"property_read",@"property":@(property),@"parameter":@(parameter),@"rc":@(rc),
        @"bytes":@(length),@"dataType":@(type),@"nativeGetter":@(native),@"sha256":rc?@"":sha(data)});
    return rc ? nil : data;
}
static BOOL capture(Ref camera,NSString *out,NSMutableDictionary *values,NSString *stage) {
    NSMutableArray *records=[NSMutableArray array];
    for (NSNumber *prop in @[@2,@7,@0x01000001,@0x01000210,@0x114,@0x115]) {
        U p=prop.unsignedIntValue; NSData *data=readProperty(camera,p,0);
        if (!data || !save(data,[out stringByAppendingPathComponent:name(p,0)])) return NO;
        values[name(p,0)]=data; [records addObject:@{@"file":name(p,0),@"bytes":@(data.length),@"sha256":sha(data)}];
    }
    if (!modelMetadata(values)) { emit(@{@"event":@"camera_metadata_rejected",@"stage":stage}); return NO; }
    for (int slot=1;slot<=3;slot++) {
        int parameter=slot+32; U rc=FreshStyle(camera,parameter);
        emit(@{@"event":@"fresh_style_request",@"stage":stage,@"slot":@(slot),@"parameter":@(parameter),@"opcode":@0x9189,@"rc":@(rc),@"cachedFallbackAllowed":@NO});
        if (rc) return NO;
        for (NSNumber *prop in @[@0x114,@0x115,@0x01000203]) {
            U p=prop.unsignedIntValue; NSData *data=readProperty(camera,p,parameter);
            if (!data || !save(data,[out stringByAppendingPathComponent:name(p,parameter)])) return NO;
            values[name(p,parameter)]=data;
            NSMutableDictionary *record=[@{@"file":name(p,parameter),@"bytes":@(data.length),@"sha256":sha(data)} mutableCopy];
            if (p==StyleProperty) record[@"colorFingerprint"]=colorFingerprint(data);
            [records addObject:record];
        }
    }
    return jsonSave(@{@"schema":@"r6m3-fresh-snapshot-v1",@"sdkSha256":SDKHash,@"model":@"0x80000518",@"firmware":@"1.1.2",
        @"descriptorSha256":DescriptorHash,@"freshSlots":@[@1,@2,@3],@"freshReadOpcode":@0x9189,@"cachedFallbackAllowed":@NO,
        @"properties":records,@"getterBackupsAreRestoreCarriers":@NO,@"stage":stage},[out stringByAppendingPathComponent:@"manifest.json"])
        && syncDirectory(out);
}
static NSDictionary *loadSnapshot(NSString *directory) {
    NSData *raw=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"manifest.json"]];
    if (!raw || raw.length>1048576) return nil;
    id m=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    if (![m isKindOfClass:NSDictionary.class] || ![m[@"schema"] isEqual:@"r6m3-fresh-snapshot-v1"] ||
        ![m[@"sdkSha256"] isEqual:SDKHash] || ![m[@"freshSlots"] isEqual:@[@1,@2,@3]] ||
        ![m[@"freshReadOpcode"] isEqual:@0x9189] || ![m[@"cachedFallbackAllowed"] isEqual:@NO]) return nil;
    NSArray *records=m[@"properties"]; if (![records isKindOfClass:NSArray.class] || records.count!=15) return nil;
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for (id record in records) {
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"file"] isKindOfClass:NSString.class]) return nil;
        NSString *file=record[@"file"];
        if (![file.lastPathComponent isEqual:file] || values[file]) return nil;
        NSData *data=boundFile([directory stringByAppendingPathComponent:file],record[@"sha256"]);
        if (!data || data.length!=[record[@"bytes"] unsignedIntegerValue]) return nil;
        values[file]=data;
    }
    if (!modelMetadata(values)) return nil;
    for (int p=33;p<=35;p++) if (!values[name(0x114,p)] || !values[name(0x115,p)] || !values[name(StyleProperty,p)]) return nil;
    return values;
}
static NSArray *loadPlan(NSString *path,NSDictionary *before,NSData **rawOut) {
    NSData *raw=[NSData dataWithContentsOfFile:path];
    if (!raw || raw.length>1048576) return nil;
    id plan=[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
    if (![plan isKindOfClass:NSDictionary.class] || ![plan[@"schema"] isEqual:@"r6m3-full33-install-v1"]) return nil;
    NSArray *slots=plan[@"slots"];
    if (![slots isKindOfClass:NSArray.class] || slots.count<1 || slots.count>3) return nil;
    NSMutableSet *seen=[NSMutableSet set]; NSMutableArray *prepared=[NSMutableArray array];
    for (id entry in slots) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"slot"] isKindOfClass:NSNumber.class]) return nil;
        int slot=[entry[@"slot"] intValue]; if (slot<1 || slot>3 || ![entry[@"slot"] isEqual:@(slot)] || [seen containsObject:@(slot)]) return nil;
        [seen addObject:@(slot)]; int parameter=slot+32;
        NSData *control=before[name(0x114,parameter)],*oldSettings=before[name(0x115,parameter)],*old=before[name(StyleProperty,parameter)];
        if (control.length!=4 || word(control,0)!=(U)(64+slot) || oldSettings.length!=32 || !knownReadback(old)) {
            emit(@{@"event":@"slot_not_initialized",@"slot":@(slot),@"requiredControl":@(64+slot),@"actualControl":@(word(control,0)),
                @"instruction":@"Initialize this slot using official EOS Utility, then create a new snapshot."}); return nil;
        }
        NSData *carrier=boundFile(entry[@"carrierFile"],entry[@"carrierSha256"]);
        id sourcePath=entry[@"sourcePf3File"] ?: entry[@"sourcePf3"];
        NSData *source=boundFile(sourcePath,entry[@"sourcePf3Sha256"]);
        NSData *manifestRaw=boundFile(entry[@"compilerManifestFile"],entry[@"compilerManifestSha256"]);
        id manifest=manifestRaw ? [NSJSONSerialization JSONObjectWithData:manifestRaw options:0 error:NULL] : nil;
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"provenance"] isKindOfClass:NSDictionary.class] ||
            ![manifest[@"pf3"] isKindOfClass:NSDictionary.class] || ![manifest[@"full33"] isKindOfClass:NSDictionary.class] ||
            ![manifest[@"settings"] isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *settingsSpec=manifest[@"settings"];
        NSData *settings=hexBytes(settingsSpec[@"hex"],32);
        if (!full33(carrier) || !source.length || ![manifest isKindOfClass:NSDictionary.class] ||
            ![manifest[@"schema"] isEqual:@"r6lut-candidate-v1"] || ![manifest[@"model"] isEqual:@"0x80000518"] ||
            ![manifest[@"firmware"] isEqual:@"1.1.2"] ||
            ![manifest[@"serializerType"] isEqual:@10] || ![manifest[@"modelAliasUsed"] isEqual:@NO] ||
            ![manifest[@"vtableHookUsed"] isEqual:@NO] || ![manifest[@"compactCipherAppliedToTables"] isEqual:@NO] ||
            ![manifest[@"nativeMetadataPreservedExact"] isEqual:@YES] || ![manifest[@"sourcePf3Unchanged"] isEqual:@YES] ||
            ![manifest[@"full33"][@"sha256"] isEqual:sha(carrier)] || ![manifest[@"full33"][@"bytes"] isEqual:@(carrier.length)] ||
            ![manifest[@"pf3"][@"sha256"] isEqual:sha(source)] || ![manifest[@"pf3"][@"bytes"] isEqual:@(source.length)] ||
            !settings || ![settingsSpec[@"bytes"] isEqual:@32] || ![sha(settings) isEqual:settingsSpec[@"sha256"]] ||
            ![manifest[@"settingsHex"] isEqual:settingsSpec[@"hex"]] ||
            ![entry[@"title"] isEqual:title(carrier)] || ![manifest[@"title"] isEqual:title(carrier)] ||
            ![manifest[@"provenance"][@"realModel"] isEqual:@"0x80000518"] ||
            ![manifest[@"provenance"][@"firmware"] isEqual:@"1.1.2"] ||
            ![manifest[@"provenance"][@"descriptorSha256"] isEqual:DescriptorHash] ||
            ![manifest[@"provenance"][@"parserSha256"] isEqual:ParserHash]) return nil;
        // Use the source PF3's exact settings, as official 203 ->115 does.
        // The original slot settings remain immutable in BEFORE. The header
        // encodes all source setting words except reserved words4/5.
        if (memcmp((const unsigned char *)carrier.bytes+80,settings.bytes,16) ||
            memcmp((const unsigned char *)carrier.bytes+104,(const unsigned char *)settings.bytes+24,8)) {
            emit(@{@"event":@"slot_settings_differ_from_source",@"slot":@(slot)}); return nil;
        }
        NSMutableDictionary *item=[entry mutableCopy]; item[@"carrierData"]=carrier; item[@"sourceData"]=source;
        item[@"compilerManifestData"]=manifestRaw; item[@"settingsData"]=settings;
        if (entry[@"restoreCarrierFile"] || entry[@"restoreCarrierSha256"]) {
            NSData *restore=boundFile(entry[@"restoreCarrierFile"],entry[@"restoreCarrierSha256"]);
            if (!full33(restore) || !metadataMatches(restore,old)) return nil;
            item[@"restoreData"]=restore;
        }
        [prepared addObject:item];
    }
    if (rawOut) *rawOut=raw; return prepared;
}
static BOOL preserveActive(Ref camera,NSDictionary *before,NSArray *items,NSString *directory,NSString *stage) {
    BOOL ok=YES;
    for (NSNumber *property in @[@0x114,@0x115]) {
        U p=property.unsignedIntValue; NSData *data=readProperty(camera,p,0);
        NSData *expected=before[name(p,0)];
        // If the global active selection already points at a replaced slot,
        // its effective settings now reflect that candidate. The selected
        // style ID itself is never changed by this helper.
        if (p==0x115) for (NSDictionary *item in items)
            if (word(before[name(0x114,0)],0)==(U)([item[@"slot"] intValue]+32) && [item[@"applied"] boolValue]) expected=item[@"settingsData"];
        BOOL same=[data isEqual:expected];
        BOOL saved=data && save(data,[directory stringByAppendingPathComponent:name(p,0)]);
        emit(@{@"event":@"active_state_verification",@"stage":stage,@"property":@(p),@"matchesExpected":@(same),@"saved":@(saved),
            @"styleSelectionUnchangedRequired":@(p==0x114)});
        if (!same || !saved) ok=NO;
    }
    return ok;
}
static U sendFull33(Ref camera,int slot,NSData *carrier,NSMutableDictionary *report) {
    if (slot<1 || slot>3 || !full33(carrier)) return 0x60;
    int parameter=slot+32;
    U rc=Set(camera,StyleProperty,parameter,(U)carrier.length,carrier.bytes);
    report[@"publicStyleSetRc"]=@(rc);
    emit(@{@"event":@"set_full33",@"api":@"EdsSetPropertyData",@"slot":@(slot),@"parameter":@(parameter),
        @"bytes":@(carrier.length),@"sha256":sha(carrier),@"rc":@(rc)});
    // In this exact SDK CEdsdk's public wrapper rejects non-allowlisted private
    // IDs before transport (GetPrivatePropertyID ->9). The exported object
    // dispatcher preserves the same five arguments and invokes the camera's
    // SetPropertyDataSelf, retaining its property/session checks. Never retry
    // a transport error, a settings write, another property, or a getter blob.
    if (rc==9 && NativeSet) {
        rc=NativeSet(camera,StyleProperty,parameter,(U)carrier.length,carrier.bytes);
        report[@"nativeStyleSetRc"]=@(rc); report[@"nativeFallbackUsed"]=@YES;
        emit(@{@"event":@"set_full33",@"api":@"CEdsObject::SetPropertyData",@"fallbackFrom":@"EdsSetPropertyData",@"publicRc":@9,
            @"slot":@(slot),@"parameter":@(parameter),@"bytes":@(carrier.length),@"sha256":sha(carrier),@"rc":@(rc),
            @"abiSymbol":@"_ZN10CEdsObject15SetPropertyDataEjijPKv",@"sdkSha256":SDKHash});
    }
    report[@"styleSetRc"]=@(rc); return rc;
}
static int install(Ref camera,NSArray *items,NSDictionary *expected,NSData *planRaw,NSString *out) {
    NSString *beforeDir=[out stringByAppendingPathComponent:@"BEFORE"];
    NSString *artifacts=[out stringByAppendingPathComponent:@"ARTIFACTS"];
    if (!newDirectory(beforeDir) || !newDirectory(artifacts)) return 1;
    NSMutableDictionary *live=[NSMutableDictionary dictionary];
    if (!capture(camera,beforeDir,live,@"install-before")) return 1;
    for (NSString *file in expected) {
        U property=[file hasPrefix:@"property-01000203-"] ? StyleProperty : 0;
        if (!sameSnapshotValue(live[file],expected[file],property)) {
            emit(@{@"event":@"snapshot_changed",@"file":file,@"oldSha256":sha(expected[file]),@"liveSha256":sha(live[file])}); return 1;
        }
    }
    if (!save(planRaw,[out stringByAppendingPathComponent:@"plan.json"])) return 1;
    NSMutableArray *reports=[NSMutableArray array];
    for (NSDictionary *item in items) {
        int slot=[item[@"slot"] intValue]; NSString *prefix=[NSString stringWithFormat:@"slot-%d",slot];
        BOOL saved=save(item[@"carrierData"],[artifacts stringByAppendingPathComponent:[prefix stringByAppendingString:@".full33.bin"]])
            && save(item[@"sourceData"],[artifacts stringByAppendingPathComponent:[prefix stringByAppendingString:@".source.pf3"]])
            && save(item[@"compilerManifestData"],[artifacts stringByAppendingPathComponent:[prefix stringByAppendingString:@".compiler.json"]]);
        if (item[@"restoreData"]) saved=saved && save(item[@"restoreData"],[artifacts stringByAppendingPathComponent:[prefix stringByAppendingString:@".original-full33.bin"]]);
        if (!saved) return 1;
        [reports addObject:[@{@"slot":@(slot),@"title":item[@"title"],@"carrierSha256":item[@"carrierSha256"],
            @"sourcePf3Sha256":item[@"sourcePf3Sha256"],@"originalReadbackBackedUp":@YES,@"originalFull33BackedUp":@(item[@"restoreData"]!=nil),
            @"automaticRollback":@NO,@"restoreNote":item[@"restoreData"]?@"Original full33 provided; retained for separately authorized recovery.":
            @"Original full33/PF3 unavailable. Getter-format backup cannot guarantee exact restoration.",@"attempted":@NO,@"freshVerified":@NO} mutableCopy]];
    }
    if (!jsonSave(reports,[out stringByAppendingPathComponent:@"backup-report.json"]) || !syncDirectory(beforeDir) || !syncDirectory(artifacts) || !syncDirectory(out)) return 1;
    emit(@{@"event":@"all_backups_complete",@"slots":@([items count]),@"immutableBefore":@YES,@"rawGetterNeverUsedForRestore":@YES});
    BOOL success=YES; NSUInteger index=0;
    for (NSDictionary *item in items) {
        NSMutableDictionary *report=reports[index++]; int slot=[item[@"slot"] intValue],parameter=slot+32;
        NSString *dir=[out stringByAppendingPathComponent:[NSString stringWithFormat:@"AFTER-slot-%d",slot]];
        if (!newDirectory(dir)) { success=NO; break; }
        if (Extend) emit(@{@"event":@"extend_shutdown_timer",@"rc":@(Extend(camera,0))});
        NSData *carrier=item[@"carrierData"],*settings=item[@"settingsData"];
        report[@"attempted"]=@YES;
        U rc=sendFull33(camera,slot,carrier,report);
        if (!rc) {
            rc=Set(camera,0x115,parameter,(U)settings.length,settings.bytes); report[@"settingsSetRc"]=@(rc);
            emit(@{@"event":@"set_slot_settings",@"api":@"EdsSetPropertyData",@"slot":@(slot),@"parameter":@(parameter),@"bytes":@(settings.length),@"sha256":sha(settings),@"rc":@(rc)});
        }
        if (!rc) ((NSMutableDictionary *)item)[@"applied"]=@YES;
        U fresh=FreshStyle(camera,parameter); report[@"freshRequestRc"]=@(fresh);
        emit(@{@"event":@"fresh_style_request",@"stage":@"after-set",@"slot":@(slot),@"opcode":@0x9189,@"rc":@(fresh),@"cachedFallbackAllowed":@NO});
        BOOL verified=rc==0 && fresh==0;
        NSData *readback=nil;
        if (!fresh) for (NSNumber *property in @[@0x114,@0x115,@0x01000203]) {
            U p=property.unsignedIntValue; NSData *data=readProperty(camera,p,parameter);
            BOOL saved=data && save(data,[dir stringByAppendingPathComponent:name(p,parameter)]);
            if (!saved) verified=NO;
            if (p==StyleProperty) { readback=data; if (!metadataMatches(carrier,data)) verified=NO; }
            else if (![data isEqual:p==0x115?settings:live[name(p,parameter)]]) verified=NO;
        }
        if (!preserveActive(camera,live,items,dir,@"after-set")) verified=NO;
        report[@"freshVerified"]=@(verified); report[@"readbackBytes"]=@(readback.length); report[@"readbackSha256"]=sha(readback);
        NSDictionary *oldColors=colorFingerprint(live[name(StyleProperty,parameter)]),*newColors=colorFingerprint(readback);
        report[@"beforeColorFingerprint"]=oldColors; report[@"afterColorFingerprint"]=newColors;
        BOOL comparable=oldColors[@"activeColorSha256"] && newColors[@"activeColorSha256"] &&
            [oldColors[@"representation"] isEqual:newColors[@"representation"]];
        report[@"colorFingerprintComparisonComparable"]=@(comparable);
        report[@"activeColorChangedFromBefore"]=comparable ? @(![oldColors[@"activeColorSha256"] isEqual:newColors[@"activeColorSha256"]]) : NSNull.null;
        report[@"verificationScope"]=@"Explicit camera retrieval, normalized metadata, slot settings/control, unchanged global active state. Color rendering is not established by structural checks.";
        if (!jsonSave(report,[dir stringByAppendingPathComponent:@"manifest.json"]) || !syncDirectory(dir)) verified=NO;
        report[@"freshVerified"]=@(verified);
        emit(@{@"event":@"slot_complete",@"slot":@(slot),@"freshVerified":@(verified),@"inputBytes":@(carrier.length),@"readbackBytes":@(readback.length),@"crossFormatByteEqualityClaimed":@NO});
        if (!verified) { success=NO; break; }
    }
    // Re-read every slot after the selected sends, so untouched-slot checks
    // also use independent camera retrieval rather than a setter cache.
    NSString *finalDir=[out stringByAppendingPathComponent:@"FINAL"];
    NSMutableDictionary *finalValues=[NSMutableDictionary dictionary];
    BOOL finalRead=newDirectory(finalDir) && capture(camera,finalDir,finalValues,@"install-final");
    if (!finalRead) success=NO;
    else for (int slot=1;slot<=3;slot++) {
        int parameter=slot+32; NSDictionary *selected=nil;
        for (NSDictionary *item in items) if ([item[@"slot"] intValue]==slot) selected=item;
        BOOL matches=YES;
        if (selected && [selected[@"applied"] boolValue]) {
            matches=metadataMatches(selected[@"carrierData"],finalValues[name(StyleProperty,parameter)])
                && [selected[@"settingsData"] isEqual:finalValues[name(0x115,parameter)]]
                && [live[name(0x114,parameter)] isEqual:finalValues[name(0x114,parameter)]];
        } else for (NSNumber *prop in @[@0x114,@0x115,@0x01000203]) {
            U p=prop.unsignedIntValue;
            if (!sameSnapshotValue(live[name(p,parameter)],finalValues[name(p,parameter)],p)) matches=NO;
        }
        emit(@{@"event":@"final_slot_verification",@"slot":@(slot),@"selected":@(selected!=nil),@"matchesExpected":@(matches),
            @"colorFingerprint":colorFingerprint(finalValues[name(StyleProperty,parameter)])});
        if (!matches) success=NO;
    }
    if (finalRead) {
        NSData *expectedSettings=live[name(0x115,0)];
        for (NSDictionary *item in items) if ([item[@"applied"] boolValue] && word(live[name(0x114,0)],0)==(U)([item[@"slot"] intValue]+32)) expectedSettings=item[@"settingsData"];
        if (![finalValues[name(0x114,0)] isEqual:live[name(0x114,0)]] || ![finalValues[name(0x115,0)] isEqual:expectedSettings]) success=NO;
    }
    if (!jsonSave(@{@"schema":@"r6m3-full33-install-result-v1",@"success":@(success),@"slots":reports,@"stateSequence":@[@"0x01000203",@"0x115"],
        @"setter":@"EdsSetPropertyData; private203 rc9 only: pinned CEdsObject dispatcher",@"currentStyleSetterUsed":@NO,@"uiLockUsed":@NO,@"automaticRollback":@NO,
        @"finalAllSlotsFreshRetrieved":@(finalRead),@"getterFormatBackupIsRestoreCarrier":@NO},[out stringByAppendingPathComponent:@"manifest.json"])) success=NO;
    return success?0:1;
}
// Enumeration only: no session, property getter/setter, shutter timer or camera
// state changes. Called once per USB connection change by the app monitor.
static int probeCamera(NSString *sdk) {
    NSString *framework=[[[sdk stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSError *error=nil;
    if (![[NSBundle bundleWithPath:framework] loadAndReturnError:&error]) {
        emit(@{@"event":@"probe_error",@"stage":@"load",@"error":error.description?:@"SDK load failed",@"styleWrites":@0,@"sessionOpened":@NO}); return 2;
    }
    module=dlopen(sdk.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    // EdsDeviceInfo is a public SDK structure; two EDS_MAX_NAME (256) strings,
    // then the public device subtype and reserved 32-bit fields.
    typedef struct { char port[256]; char description[256]; U subtype; U reserved; } ProbeDeviceInfo;
    U (*DeviceInfo)(Ref,ProbeDeviceInfo *)=NULL;
    if (!module || !symbol(&Init,"EdsInitializeSDK",YES) || !symbol(&Term,"EdsTerminateSDK",YES)
        || !symbol(&List,"EdsGetCameraList",YES) || !symbol(&Count,"EdsGetChildCount",YES)
        || !symbol(&Child,"EdsGetChildAtIndex",YES) || !symbol(&Release,"EdsRelease",YES)
        || !symbol(&DeviceInfo,"EdsGetDeviceInfo",YES)) return 2;
    [NSApplication sharedApplication]; U rc=Init();
    emit(@{@"event":@"probe_initialize",@"rc":@(rc),@"styleWrites":@0,@"sessionOpened":@NO});
    if (rc) return 1;
    Ref list=NULL; U count=0; int attempts=0; NSMutableArray *cameras=[NSMutableArray array];
    @try {
        // Canon USB discovery is asynchronous. Pump a bounded run loop instead
        // of holding a session or retrying periodically while the app is idle.
        for (attempts=0;attempts<24;attempts++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            if (list) { Release(list); list=NULL; }
            count=0; rc=List(&list); if (!rc && list) rc=Count(list,&count);
            if (rc || count) break;
        }
        if (!rc) for (U index=0;index<count;index++) {
            Ref camera=NULL; U childRc=Child(list,(int)index,&camera);
            if (childRc || !camera) { [cameras addObject:@{@"deviceInfoRc":@(childRc?:1)}]; continue; }
            ProbeDeviceInfo info={0}; U infoRc=DeviceInfo(camera,&info); Release(camera);
            info.port[255]=0; info.description[255]=0;
            NSString *label=[NSString stringWithUTF8String:info.description]?:@"Canon 相机";
            [cameras addObject:@{@"name":label,@"port":[NSString stringWithUTF8String:info.port]?:@"",
                @"deviceSubType":@(info.subtype),@"deviceInfoRc":@(infoRc)}];
        }
        emit(@{@"event":@"probe_complete",@"rc":@(rc),@"cameraCount":@(count),@"cameras":cameras,
            @"waitedMilliseconds":@((MIN(attempts+1,24))*500),@"sessionOpened":@NO,@"styleWrites":@0});
    } @catch (NSException *exception) {
        rc=1; emit(@{@"event":@"probe_error",@"stage":@"enumerate",@"error":exception.reason?:@"unknown"});
    } @finally {
        if (list) Release(list);
        emit(@{@"event":@"probe_terminate",@"rc":@(Term()),@"sessionOpened":@NO,@"styleWrites":@0});
    }
    return rc?1:0;
}
int main(int argc,const char **argv) { @autoreleasepool {
    BOOL probing=argc==3 && strcmp(argv[1],"probe")==0;
    BOOL snapshot=argc==4 && strcmp(argv[1],"snapshot")==0;
    BOOL installing=argc==7 && strcmp(argv[1],"install")==0 && strcmp(argv[6],"--validated-full33")==0;
    BOOL validate=argc==5 && strcmp(argv[1],"validate")==0;
    if (!probing && !snapshot && !installing && !validate) {
        fprintf(stderr,"usage: eds_r6_tool probe SDK (enumeration only; no session)\n       eds_r6_tool snapshot SDK NEW-dir\n       eds_r6_tool install SDK BEFORE-dir plan.json NEW-dir --validated-full33\n       eds_r6_tool validate SDK BEFORE-dir plan.json (offline; no SDK loading)\n"); return 2;
    }
    NSString *sdk=[[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
    NSString *out=snapshot?[[NSString stringWithUTF8String:argv[3]] stringByStandardizingPath]:
        installing?[[NSString stringWithUTF8String:argv[5]] stringByStandardizingPath]:nil;
    if (!sdk.isAbsolutePath || (out && (!out.isAbsolutePath || [[NSFileManager defaultManager] fileExistsAtPath:out]))) {
        fprintf(stderr,"Absolute paths and a new output directory are required.\n"); return 2;
    }
    if (![[sha([NSData dataWithContentsOfFile:sdk]) lowercaseString] isEqual:SDKHash]) {
        fprintf(stderr,"Pinned SDK hash differs. No SDK initialized.\n"); return 2;
    }
    if (probing) return probeCamera(sdk);
    NSDictionary *before=nil; NSArray *items=nil; NSData *planRaw=nil;
    if (installing || validate) {
        NSString *beforePath=[[NSString stringWithUTF8String:argv[3]] stringByStandardizingPath];
        NSString *planPath=[[NSString stringWithUTF8String:argv[4]] stringByStandardizingPath];
        if (!beforePath.isAbsolutePath || !planPath.isAbsolutePath || !(before=loadSnapshot(beforePath)) || !(items=loadPlan(planPath,before,&planRaw))) {
            emit(@{@"event":@"offline_preflight_failed",@"sdkInitialized":@NO}); return 2;
        }
        if (validate) { emit(@{@"event":@"offline_preflight_passed",@"sdkLoaded":@NO,@"sdkInitialized":@NO,@"slots":@([items count])}); return 0; }
    }
    if (!newDirectory(out)) return 2;
    auditFile=fopen([[out stringByAppendingPathComponent:@"events.jsonl"] fileSystemRepresentation],"wx");
    if (!auditFile) return 2;
    NSString *framework=[[[sdk stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSError *error=nil;
    if (![[NSBundle bundleWithPath:framework] loadAndReturnError:&error]) { emit(@{@"event":@"bundle_load_error",@"error":error.description?:@"unknown"}); fclose(auditFile); return 2; }
    module=dlopen(sdk.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL); if (!module) { fclose(auditFile); return 2; }
    BOOL symbols=symbol(&Init,"EdsInitializeSDK",YES)&&symbol(&Term,"EdsTerminateSDK",YES)&&symbol(&List,"EdsGetCameraList",YES)&&symbol(&Count,"EdsGetChildCount",YES)
        &&symbol(&Child,"EdsGetChildAtIndex",YES)&&symbol(&Open,"EdsOpenSession",YES)&&symbol(&Close,"EdsCloseSession",YES)&&symbol(&Release,"EdsRelease",YES)
        &&symbol(&PropSize,"EdsGetPropertySize",YES)&&symbol(&Get,"EdsGetPropertyData",YES)
        &&symbol(&NativeSize,"_ZN10CPtpCamera15GetPropertySizeEjiP11EdsDataTypePj",YES)
        &&symbol(&NativeGet,"_ZN10CPtpCamera15GetPropertyDataEjijPv",YES)&&symbol(&FreshStyle,"_ZN10CPtpCamera23GetUserPictureStyleDataEi",YES);
    if (installing) symbols=symbols&&symbol(&Set,"EdsSetPropertyData",YES)
        &&symbol(&NativeSet,"_ZN10CEdsObject15SetPropertyDataEjijPKv",YES);
    symbol(&Extend,"_ZN10CPtpCamera19ExtendShutDownTimerEi",NO);
    if (!symbols) { fclose(auditFile); return 2; }
    [NSApplication sharedApplication]; U rc=Init(); emit(@{@"event":@"initialize",@"rc":@(rc),@"sdkSha256":SDKHash});
    if (rc) { fclose(auditFile); return 1; }
    Ref list=NULL,camera=NULL; BOOL opened=NO; int result=1;
    @try {
        BOOL found=NO;
        for (int attempt=0;attempt<=10;attempt++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:attempt==0?10:1]];
            if (list) { Release(list); list=NULL; }
            U count=0; rc=List(&list); if (!rc && list) rc=Count(list,&count);
            emit(@{@"event":@"discovery",@"attempt":@(attempt),@"waitedSeconds":@(10+attempt),@"rc":@(rc),@"count":@(count)});
            if (!rc && list && count==1) { found=YES; break; }
            if (!rc && count>1) break;
        }
        if (!found) return 1;
        rc=Child(list,0,&camera); if (rc || !camera) return 1;
        rc=Open(camera); emit(@{@"event":@"open_session",@"rc":@(rc)}); if (rc) return 1; opened=YES;
        if (Extend) emit(@{@"event":@"extend_shutdown_timer",@"rc":@(Extend(camera,0))});
        if (snapshot) {
            NSMutableDictionary *values=[NSMutableDictionary dictionary];
            result=capture(camera,out,values,@"snapshot")?0:1;
            emit(@{@"event":@"snapshot_complete",@"success":@(result==0),@"properties":@(values.count),@"styleWrites":@0});
        } else result=install(camera,items,before,planRaw,out);
    } @catch (NSException *exception) { emit(@{@"event":@"exception",@"reason":exception.reason?:@"unknown"}); result=1; }
    @finally {
        if (opened) emit(@{@"event":@"close_session",@"rc":@(Close(camera))});
        if (camera) Release(camera); if (list) Release(list);
        emit(@{@"event":@"terminate",@"rc":@(Term()),@"result":@(result)}); fclose(auditFile); auditFile=NULL;
    }
    return result;
}}
