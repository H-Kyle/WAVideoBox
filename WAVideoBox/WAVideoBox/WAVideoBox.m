//
//  WAVideoTool.m
//  WA
//
//  Created by 黄锐灏 on 17/4/24.
//  Copyright © 2017年 黄锐灏. All rights reserved.
//

#import "WAVideoBox.h"
#import <Photos/Photos.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "WAAVSEExportCommand.h"
#import "WAAVSEVideoMixCommand.h"
#import "WAAVSEImageMixCommand.h"
#import "WAAVSEReplaceSoundCommand.h"
#import "WAAVSEGearboxCommand.h"
#import "WAAVSERangeCommand.h"
#import "WAAVSERotateCommand.h"
#import "WAAVSEDubbedCommand.h"
#import <pthread.h>

@interface WAVideoBox ()

@property (nonatomic , strong) WAAVSEComposition *cacheComposition;

@property (nonatomic , strong) NSMutableArray <WAAVSEComposition *>*workSpace;

@property (nonatomic , strong) NSMutableArray <WAAVSEComposition *>*composeSpace;

@property (nonatomic , strong) NSMutableArray <NSString *>*tmpVideoSpace;

@property (nonatomic , weak) WAAVSEExportCommand *exportCommand;

@property (nonatomic , assign) NSInteger directCompostionIndex;

@property (nonatomic , copy) NSString *filePath;

@property (nonatomic , copy) NSString *tmpPath;

@property (nonatomic , copy) void (^editorComplete)(NSError *error);

@property (nonatomic , copy) NSString *presetName;

@property (nonatomic , assign ,getter=isSuspend) BOOL suspend; //线程 挂起

@property (nonatomic , assign ,getter=isCancel) BOOL cancel; //线程 挂起

@end

dispatch_queue_t _contextQueue;
static void *contextQueueKey = &contextQueueKey;

dispatch_queue_t _processQueue;
static void *processQueueKey = &processQueueKey;

NSString *_tmpDirectory;


void runSynchronouslyOnVideoProcessingQueue(void (^block)(void))
{
    if (dispatch_get_specific(processQueueKey)){
        block();
    }else{
        dispatch_sync(_processQueue, block);
    }
}

void runAsynchronouslyOnVideoProcessingQueue(void (^block)(void))
{
    
    dispatch_async(_processQueue, block);
}

void runSynchronouslyOnVideoContextQueue(void (^block)(void))
{
    if (dispatch_get_specific(contextQueueKey)){
        block();
    }else{
        dispatch_sync(_contextQueue, block);
    }
}

void runAsynchronouslyOnVideoContextQueue(void (^block)(void))
{
    
    dispatch_async(_contextQueue, block);
}

@implementation WAVideoBox


+ (void)initialize{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _tmpDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"WAVideoBoxTmp"];
      
        processQueueKey = &processQueueKey;
        
        _contextQueue = dispatch_queue_create("VideoBoxContextQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_contextQueue, contextQueueKey, &contextQueueKey, NULL);
        
        _processQueue = dispatch_queue_create("VideoBoxProcessQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_processQueue, processQueueKey, &processQueueKey, NULL);
    
        if (![[NSFileManager defaultManager] fileExistsAtPath:_tmpDirectory]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:_tmpDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    });
}

#pragma mark life cycle
- (instancetype)init{
    self = [super init];
    
    self.videoQuality = 0;
    self.ratio = WAVideoExportRatio960x540;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(AVEditorNotification:) name:WAAVSEExportCommandCompletionNotification object:nil];
    
    return self;
}

- (void)dealloc{
    if (self.isSuspend) {
        dispatch_resume(_contextQueue);
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark pubilc method
#pragma mark 资源
- (BOOL)appendVideoByPath:(NSString *)videoPath{
    
    if (videoPath.length == 0 ) {
        return NO;
    }
    
    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
    return [self appendVideoByAsset:asset];
    
}

- (BOOL)appendVideoByAsset:(AVAsset *)videoAsset{
    
    if (!videoAsset || !videoAsset.playable) {
        return NO;
    }
    
    runSynchronouslyOnVideoProcessingQueue(^{ // 取消指令
        self.cancel = NO;
    });
    
    runAsynchronouslyOnVideoContextQueue(^{
        // 清空工作区
        [self commitCompostionToComposespace];
        
        if (!self.cacheComposition) {
            self.cacheComposition = [WAAVSEComposition new];
            self.cacheComposition.presetName = self.presetName;
            self.cacheComposition.videoQuality = self.videoQuality;
            WAAVSECommand *command = [[WAAVSECommand alloc] initWithComposition:self.cacheComposition];
            [command performWithAsset:videoAsset];
        }else{
            WAAVSEVideoMixCommand *mixcommand = [[WAAVSEVideoMixCommand alloc] initWithComposition:self.cacheComposition];
            [mixcommand performWithAsset:self.cacheComposition.mutableComposition mixAsset:videoAsset];
        }
        
    });
    return YES;
}

- (void)commit{
    
    runAsynchronouslyOnVideoContextQueue(^{
  
        [self.workSpace insertObjects:self.composeSpace atIndexes:[[NSIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, self.composeSpace.count)]];
        
        [self.composeSpace removeAllObjects];
        
        [self commitCompostionToWorkspace];
        
    });
    
}

#pragma mark 裁剪
- (BOOL)rangeVideoByTimeRange:(CMTimeRange)range{
    
    runAsynchronouslyOnVideoContextQueue(^{

        [self commitCompostionToWorkspace];
        
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSERangeCommand *rangeCommand = [[WAAVSERangeCommand alloc] initWithComposition:composition];
            [rangeCommand performWithAsset:composition.mutableComposition timeRange:range];
        }
    });
  
    return YES;
}

- (BOOL)rotateVideoByDegress:(NSInteger)degress{
    
    runAsynchronouslyOnVideoContextQueue(^{

        [self commitCompostionToWorkspace];
        
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSERotateCommand *rotateCommand = [[WAAVSERotateCommand alloc] initWithComposition:composition];
            [rotateCommand performWithAsset:composition.mutableComposition degress:degress];
        }
 
    });
    
    return YES;
    
}

- (BOOL)appendWaterMark:(UIImage *)waterImg relativeRect:(CGRect)relativeRect{
    
    if (!waterImg) {
        return NO;
    }
    
    runAsynchronouslyOnVideoContextQueue(^{
        
        [self commitCompostionToWorkspace];
        
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSEImageMixCommand *command = [[WAAVSEImageMixCommand alloc] initWithComposition:composition];
            command.imageBg = NO;
            command.image = waterImg;
            [command imageLayerRectWithVideoSize:^CGRect(CGSize videoSize) {
                return CGRectMake(videoSize.width * relativeRect.origin.x,videoSize.height * (1 - relativeRect.origin.y) - videoSize.height * relativeRect.size.height,videoSize.width * relativeRect.size.width, videoSize.height * relativeRect.size.height);
            }];
            [command performWithAsset:composition.mutableComposition];
        }
 
    });
    
    return YES;
}

#pragma mark 变速
- (BOOL)gearBoxWithScale:(CGFloat)scale{
    
    runAsynchronouslyOnVideoContextQueue(^{
        [self commitCompostionToWorkspace];
        
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSEGearboxCommand *gearBox =  [[WAAVSEGearboxCommand alloc] initWithComposition:composition];
            [gearBox performWithAsset:composition.mutableComposition scale:scale];
        }
    });
    return YES;
}

- (BOOL)gearBoxTimeByScaleArray:(NSArray<WAAVSEGearboxCommandModel *> *)scaleArray{
    
    if (!scaleArray.count) {
        return NO;
    }
    

    runAsynchronouslyOnVideoContextQueue(^{
       
        [self commitCompostionToWorkspace];
        
        
        for (WAAVSEComposition *composition in self.workSpace) {
           
            WAAVSEGearboxCommand *gearBox =  [[WAAVSEGearboxCommand alloc] initWithComposition:composition];
            [gearBox performWithAsset:composition.mutableComposition models:scaleArray];
        }
    });
    
    return YES;
}

#pragma mark 换音
- (BOOL)replaceSoundBySoundPath:(NSString *)soundPath{
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:soundPath]) {
        return NO;
    }
    
    AVAsset *soundAsset = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:soundPath] options:nil];
    if (!soundAsset.playable) {
        return NO;
    }
    runAsynchronouslyOnVideoContextQueue(^{
        [self commitCompostionToWorkspace];
        
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSEReplaceSoundCommand *replaceCommand = [[WAAVSEReplaceSoundCommand alloc] initWithComposition:composition];
            [replaceCommand performWithAsset:composition.mutableComposition replaceAsset:soundAsset];
        }
    });
    
    
    return YES;
}

#pragma mark 混音
- (BOOL)dubbedSoundBySoundPath:(NSString *)soundPath{
    
    return [self dubbedSoundBySoundPath:soundPath volume:0.5 mixVolume:0.5 insertTime:0];
}

- (BOOL)dubbedSoundBySoundPath:(NSString *)soundPath volume:(CGFloat)volume mixVolume:(CGFloat)mixVolume insertTime:(CGFloat)insetDuration{
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:soundPath]) {
        return NO;
    }
    
    AVAsset *soundAsset = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:soundPath] options:nil];
    if (!soundAsset.playable) {
        return NO;
    }
    
    runAsynchronouslyOnVideoContextQueue(^{
        [self commitCompostionToWorkspace];
        for (WAAVSEComposition *composition in self.workSpace) {
            WAAVSEDubbedCommand *command = [[WAAVSEDubbedCommand alloc] initWithComposition:composition];
            command.insertTime = CMTimeMakeWithSeconds(insetDuration, composition.mutableComposition.duration.timescale);
            command.audioVolume = volume;
            command.mixVolume = mixVolume;
            [command performWithAsset:composition.mutableComposition mixAsset:soundAsset];
        }
    });
    
    return YES;
}

#pragma mark video edit

- (void)syncFinishEditByFilePath:(NSString *)filePath complete:(void (^)(NSError *))complete{
    runSynchronouslyOnVideoContextQueue(^{
        [self finishEditByFilePath:filePath complete:complete];
    });
}

- (void)asyncFinishEditByFilePath:(NSString *)filePath complete:(void (^)(NSError *))complete{
    runAsynchronouslyOnVideoContextQueue(^{
        [self finishEditByFilePath:filePath complete:complete];
    });
}

- (void)cancelEdit{
    
    runSynchronouslyOnVideoProcessingQueue(^{
        self.cancel = YES;
        if (self.exportCommand.exportSession.status == AVAssetExportSessionStatusExporting) {
            [self.exportCommand.exportSession cancelExport];
            NSLog(@"%s",__func__);
        }
    });
}

- (void)clean{
    
    runAsynchronouslyOnVideoContextQueue(^{
        [self __internalClean];
    });

}

- (void)__internalClean{
    
    for (NSString *tmpPath in self.tmpVideoSpace) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:tmpPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        }
    }
    
    [self.tmpVideoSpace removeAllObjects];
    [self.workSpace removeAllObjects];
    [self.composeSpace removeAllObjects];
    self.editorComplete = nil;
    self.filePath = nil;
    self.tmpPath = nil;
    
    self.directCompostionIndex = 0;
    
}

#pragma mark private
- (void)commitCompostionToWorkspace{
    if (self.cacheComposition) {
        [self.workSpace addObject:self.cacheComposition];
        self.cacheComposition = nil;
    }
}

- (void)commitCompostionToComposespace{
    
    if (!self.workSpace.count) {
        return;
    }
    
    // workspace的最后一个compostion可寻求合并
    for (int i = 0; i < self.workSpace.count - 1; i++) {
        [self.composeSpace addObject:self.workSpace[i]];
    }
    
    WAAVSEComposition *currentComposition = [self.workSpace lastObject];
    
    [self.workSpace removeAllObjects];
    
    if (!currentComposition.mutableVideoComposition && !currentComposition.mutableAudioMix && self.composeSpace.count == self.directCompostionIndex) { // 可以直接合并
        if (self.composeSpace.count > 0) {
            WAAVSEComposition *compositon = [self.composeSpace lastObject];
            
            WAAVSEVideoMixCommand *mixCommand = [[WAAVSEVideoMixCommand alloc] initWithComposition:compositon];
            [mixCommand performWithAsset:compositon.mutableComposition mixAsset:(AVAsset *)currentComposition.mutableComposition];
        }else{
            self.directCompostionIndex = self.composeSpace.count;
            [self.composeSpace addObject:currentComposition];
        }
    }else{
         [self.composeSpace addObject:currentComposition];
    }

}

- (void)processVideoByComposition:(WAAVSEComposition *)composition{
    
    NSString *filePath = self.filePath;
    if(self.composeSpace.count != 1 || self.tmpVideoSpace.count){
        self.tmpPath = filePath = [self tmpVideoFilePath];
    }
    
    WAAVSEExportCommand *exportCommand = [[WAAVSEExportCommand alloc] initWithComposition:composition];
    self.exportCommand = exportCommand;
    [exportCommand performSaveByPath:filePath];


}

- (void)successToProcessCurrentCompostion{
    
    [self.composeSpace removeObjectAtIndex:0];
    [self.tmpVideoSpace addObject:self.tmpPath];
    
    if (self.composeSpace.count > 0) {
        [self processVideoByComposition:self.composeSpace.firstObject];
    }else{
        self.tmpPath = nil;
        
        WAAVSEVideoMixCommand *mixComand = [WAAVSEVideoMixCommand new];
        
        NSMutableArray *assetAry = [NSMutableArray array];
        for (NSString *filePath in self.tmpVideoSpace) {
            [assetAry addObject:[AVAsset assetWithURL:[NSURL fileURLWithPath:filePath]]];
        }
        [mixComand performWithAssets:assetAry];
        mixComand.composition.presetName = self.presetName;
        mixComand.composition.videoQuality = self.videoQuality;
        
        WAAVSEExportCommand *exportCommand = [[WAAVSEExportCommand alloc] initWithComposition:mixComand.composition];
        self.exportCommand = exportCommand;
        [exportCommand performSaveByPath:self.filePath];
       
    }
}

- (void)failToProcessVideo:(NSError *)error{
   
    // 清理失败文件
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.filePath]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:nil];
    }
    
    if (self.editorComplete) {
        self.editorComplete(error);
    }
    
    [self __internalClean];
    
    if (self.suspend) {
        self.suspend = NO;
        dispatch_resume(_contextQueue);
    }
    
}

- (void)successToProcessVideo{
    
    if (self.editorComplete) {
        void (^editorComplete)(NSError *error) = self.editorComplete;
        dispatch_async(dispatch_get_main_queue(), ^{
            editorComplete(nil);
        });
    }
    [self __internalClean];
    
    if (self.suspend) {
        self.suspend = NO;
        dispatch_resume(_contextQueue);
    }
   
}

- (void)finishEditByFilePath:(NSString *)filePath complete:(void (^)(NSError *error))complete{
    
    [self commitCompostionToWorkspace];
    
    [self commitCompostionToComposespace];
    
    if (!self.composeSpace.count) {
        complete([NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorNoDataCaptured userInfo:nil]);
        return;
    }
    
    self.filePath = filePath;
    self.editorComplete = complete;
    
    runSynchronouslyOnVideoProcessingQueue(^{
        
        self.suspend = YES;
        dispatch_suspend(_contextQueue);
        
        if (self.cancel) {
            [self failToProcessVideo:[NSError errorWithDomain:AVFoundationErrorDomain code:-10000 userInfo:@{NSLocalizedFailureReasonErrorKey:@"User cancel process!"}]];
            return ;
        }else{
            [self processVideoByComposition:self.composeSpace.firstObject];
            return ;
        }
    });
    
    
}

- (NSString *)tmpVideoFilePath{
    return [_tmpDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%f.mp4",[NSDate timeIntervalSinceReferenceDate]]];
}

#pragma mark notification
- (void)AVEditorNotification:(NSNotification *)notification{
    
    runAsynchronouslyOnVideoProcessingQueue(^{
        if ([[notification name] isEqualToString:WAAVSEExportCommandCompletionNotification] && self.exportCommand == notification.object) {
            
            NSError *error = [notification.userInfo objectForKey:WAAVSEExportCommandError];
            
            if (self.cancel) {
                error = [NSError errorWithDomain:AVFoundationErrorDomain code:-10000 userInfo:@{NSLocalizedFailureReasonErrorKey:@"User cancel process!"}];
            }
            
            if (error) {
                [self failToProcessVideo:error];
            }else{
                if(!self.tmpPath){// 成功合成
                    [self successToProcessVideo];
                }else{
                    [self successToProcessCurrentCompostion];
                }
            }
            
        }
    });
    
}


#pragma mark getter and setter
- (void)setRatio:(WAVideoExportRatio)ratio{
    
    if (self.workSpace.count) {
        return;
    }
    
    _ratio = ratio;
    switch (self.ratio) {
        case WAVideoExportRatio640x480:
            self.presetName = AVAssetExportPreset640x480;
            break;
        case WAVideoExportRatio960x540:
            self.presetName = AVAssetExportPreset960x540;
            break;
        case WAVideoExportRatio1280x720:
            self.presetName = AVAssetExportPreset1280x720;
            break;
        case WAVideoExportRatioHighQuality:
            self.presetName = AVAssetExportPresetHighestQuality;
            break;
        case WAVideoExportRatioMediumQuality:
            self.presetName = AVAssetExportPresetMediumQuality;
            break;
        case WAVideoExportRatioLowQuality:
            self.presetName = AVAssetExportPresetLowQuality;
            break;
        default:
            break;
    }
}

#pragma mark getter
- (NSMutableArray *)composeSpace{
    if (!_composeSpace) {
        if (!_composeSpace) {
             _composeSpace = [NSMutableArray array];
        }
    }
    return _composeSpace;
}

- (NSMutableArray *)workSpace{
    if (!_workSpace) {
        if (!_workSpace) {
            _workSpace = [NSMutableArray array];
        }
    }
    return _workSpace;
}

- (NSMutableArray *)tmpVideoSpace{
    if (!_tmpVideoSpace) {
        if (!_tmpVideoSpace) {
            _tmpVideoSpace = [NSMutableArray array];
        }
    }
    return _tmpVideoSpace;
}
@end
