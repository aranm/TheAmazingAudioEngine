//
//  AEAudioUnitFilePlayer.h
//  TheAmazingAudioEngine
//
//  Created by Aran Mulholland on 19/11/2013.
//  Copyright (c) 2013 A Tasty Pixel. All rights reserved.
//
#ifdef __cplusplus
extern "C" {
#endif

#import "TheAmazingAudioEngine.h"

@interface AEAudioUnitFilePlayer : AEAudioUnitChannel <AEAudioTimingReceiver> {
    AudioUnit filePlayerUnit_;
    BOOL fileIsValid;
    AudioFileID audioFile;
    AudioStreamBasicDescription fileFormat;
    UInt64 numberOfPackets;
    UInt64 fileDuration;
    
    
    Float64 currentTimeStamp_;
    AEBlockScheduler *blockScheduler_;
    
}

/*!
 * Create a new player instance
 *
 * @param url               URL to the file to load
 * @param audioController   The audio controller
 * @param error             If not NULL, the error on output
 * @return The audio player, ready to be @link AEAudioController::addChannels: added @endlink to the audio controller.
 */
- (id)initAudioUnitFilePlayerWithAudioController:(AEAudioController*)audioController
                                           error:(NSError**)error;


- (id)initAudioUnitFilePlayerWithAudioController:(AEAudioController*)audioController
                              preInitializeBlock:(void(^)(AudioUnit audioUnit))block
                                           error:(NSError**)error;


- (void)loadAudioFileFromUrl:(NSURL *)fileUrl;
- (void)play;
- (BOOL)stop;

//- (BOOL)playWithOffset:(UInt32)timeStamp;

@property (nonatomic, retain, readonly) NSURL *url;         //!< Original media URL
@property (nonatomic, readonly) NSTimeInterval duration;    //!< Length of audio, in seconds
@property (nonatomic, assign) NSTimeInterval currentTime;   //!< Current playback position, in seconds
@property (nonatomic, readwrite) BOOL loop;                 //!< Whether to loop this track
@property (nonatomic, readwrite) float volume;              //!< Track volume
@property (nonatomic, readwrite) float pan;                 //!< Track pan
@property (nonatomic, readwrite) BOOL channelIsPlaying;     //!< Whether the track is playing
@property (nonatomic, readwrite) BOOL channelIsMuted;       //!< Whether the track is muted
@property (nonatomic, readwrite) BOOL removeUponFinish;     //!< Whether the track automatically removes itself from the audio controller after playback completes
@property (nonatomic, copy) void(^completionBlock)();       //!< A block to be called when playback finishes
@property (nonatomic, copy) void(^startLoopBlock)();        //!< A block to be called when the loop restarts in loop mode

@end

#ifdef __cplusplus
}
#endif