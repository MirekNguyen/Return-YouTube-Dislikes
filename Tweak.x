#import <HBLog.h>
#import <UIKit/UIKit.h>
#import "API.h"
#import "Settings.h"
#import "Shared.h"
#import "Tweak.h"
#import "TweakSettings.h"
#import "Vote.h"

@interface ASCollectionView (RYD)
@property (nonatomic, assign) BOOL hasDislikeIntent;
@property (nonatomic, assign) BOOL isProbablyVideoDescriptionHeaderPanel;
@end

static NSCache <NSString *, NSDictionary *> *cache;
NSString *localizedDislikeText = nil;

extern NSBundle *RYDBundle();

%hook YTReelWatchLikesController

- (void)updateLikeButtonWithRenderer:(YTILikeButtonRenderer *)renderer {
    %orig;
    if (!TweakEnabled()) return;
    YTQTMButton *dislikeButton = self.dislikeButton;
    [dislikeButton setTitle:FETCHING forState:UIControlStateNormal];
    [dislikeButton setTitle:FETCHING forState:UIControlStateSelected];
    YTLikeStatus likeStatus = renderer.likeStatus;
    getVoteFromVideoWithHandler(cache, renderer.target.videoId, maxRetryCount, ^(NSDictionary *data, NSString *error) {
        NSString *formattedDislikeCount = getNormalizedDislikes(getDislikeData(data), error);
        NSString *formattedToggledDislikeCount = getNormalizedDislikes(@([getDislikeData(data) unsignedIntegerValue] + 1), error);
        YTIFormattedString *formattedText = [%c(YTIFormattedString) formattedStringWithString:formattedDislikeCount];
        YTIFormattedString *formattedToggledText = [%c(YTIFormattedString) formattedStringWithString:formattedToggledDislikeCount];
        if (renderer.hasDislikeCountText)
            renderer.dislikeCountText = formattedText;
        if (renderer.hasDislikeCountWithDislikeText)
            renderer.dislikeCountWithDislikeText = formattedToggledText;
        if (renderer.hasDislikeCountWithUndislikeText)
            renderer.dislikeCountWithUndislikeText = formattedText;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (likeStatus == YTLikeStatusDislike) {
                [dislikeButton setTitle:[renderer.dislikeCountWithUndislikeText stringWithFormattingRemoved] forState:UIControlStateNormal];
                [dislikeButton setTitle:[renderer.dislikeCountText stringWithFormattingRemoved] forState:UIControlStateSelected];
            } else {
                [dislikeButton setTitle:[renderer.dislikeCountText stringWithFormattingRemoved] forState:UIControlStateNormal];
                [dislikeButton setTitle:[renderer.dislikeCountWithDislikeText stringWithFormattingRemoved] forState:UIControlStateSelected];
            }
        });
        if ((ExactLikeNumber() || UseRYDLikeData()) && error == nil) {
            YTQTMButton *likeButton = self.likeButton;
            NSString *formattedLikeCount = getNormalizedLikes(getLikeData(data), nil);
            NSString *formattedToggledLikeCount = getNormalizedDislikes(@([getLikeData(data) unsignedIntegerValue] + 1), nil);
            YTIFormattedString *formattedText = [%c(YTIFormattedString) formattedStringWithString:formattedLikeCount];
            YTIFormattedString *formattedToggledText = [%c(YTIFormattedString) formattedStringWithString:formattedToggledLikeCount];
            if (renderer.hasLikeCountText)
                renderer.likeCountText = formattedText;
            if (renderer.hasLikeCountWithLikeText)
                renderer.likeCountWithLikeText = formattedToggledText;
            if (renderer.hasLikeCountWithUnlikeText)
                renderer.likeCountWithUnlikeText = formattedText;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (likeStatus == YTLikeStatusLike) {
                    [likeButton setTitle:[renderer.likeCountWithUnlikeText stringWithFormattingRemoved] forState:UIControlStateNormal];
                    [likeButton setTitle:[renderer.likeCountText stringWithFormattingRemoved] forState:UIControlStateSelected];
                } else {
                    [likeButton setTitle:[renderer.likeCountText stringWithFormattingRemoved] forState:UIControlStateNormal];
                    [likeButton setTitle:[renderer.likeCountWithLikeText stringWithFormattingRemoved] forState:UIControlStateSelected];
                }
            });
        }
    });
}

%end

%hook YTLikeService

- (void)notifyVideoLikeStatus:(YTLikeStatus)likeStatus withID:(NSString *)videoId {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(videoId, likeStatus);
    %orig;
}

- (void)notifyPlaylistLikeStatus:(YTLikeStatus)likeStatus withID:(NSString *)playlistId {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(playlistId, likeStatus);
    %orig;
}

%end

%hook YTLikeServiceImpl

- (void)notifyVideoLikeStatus:(YTLikeStatus)likeStatus withID:(NSString *)videoId {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(videoId, likeStatus);
    %orig;
}

- (void)notifyPlaylistLikeStatus:(YTLikeStatus)likeStatus withID:(NSString *)playlistId {
    if (TweakEnabled() && VoteSubmissionEnabled())
        sendVote(playlistId, likeStatus);
    %orig;
}

%end

int overrideNodeCreation = 0;

static NSString *getElementDescription(ELMCellNode *node) {
    HBLogDebug(@"RYD: Found node: %@", node);
    if (![node isKindOfClass:%c(ELMCellNode)]) return nil;
    ELMNodeController *controller = [node controller];
    HBLogDebug(@"RYD: Found controller: %@", controller);
    return [[controller owningComponent] description];
}

// The action bar's host collection view was renamed. "id.video.scrollable_action_bar"
// does not exist anywhere in the YouTube 21.33.6 binary; the only remaining
// action-bar identifier is "id.video.detailsactions.view", the collection view
// inside YTSlimVideoScrollableDetailsActionsView. Matching only the old name is
// why the like/dislike row renders with no counts at all on current builds.
//
// Both names are accepted so this keeps working on older YouTube versions. It
// is safe to be permissive here: the caller re-validates the node tree and
// bails unless it finds "id.video.like.button" where it expects it, so a false
// positive costs a tree walk and nothing else.
static BOOL isVideoScrollableActionBar(ASCollectionView *collectionView, ELMCellNode *node) {
    NSString *identifier = collectionView.accessibilityIdentifier;
    return [identifier isEqualToString:@"id.video.scrollable_action_bar"]
        || [identifier isEqualToString:@"id.video.detailsactions.view"];
}

static BOOL isVideoDescriptionHeader(ASCollectionView *collectionView, ELMCellNode *node) {
    return [getElementDescription(node) containsString:@"video_description_header.eml"];
}

__strong ELMTextNode *likeTextNode = nil;
__strong YTRollingNumberNode *likeRollingNumberNode = nil;
__strong ELMTextNode *dislikeTextNode = nil;
__strong YTRollingNumberNode *dislikeRollingNumberNode = nil;

__strong ELMTextNode *infoLikeTextNode = nil;
__strong YTRollingNumberNode *infoLikeRollingNumberNode = nil;
__strong YTRollingNumberNode *infoDislikeRollingNumberNode = nil;

__strong NSMutableAttributedString *mutableDislikeText = nil;

static NSString *getVideoId(ASDisplayNode *containerNode) {
    UIViewController *vc = [containerNode closestViewController];
    if (![vc isKindOfClass:%c(YTWatchNextResultsViewController)]) {
        UIViewController *parentViewController;
        do {
            parentViewController = vc.parentViewController;
            if ([parentViewController isKindOfClass:%c(YTWatchViewController)]) {
                vc = parentViewController;
                break;
            }
            vc = parentViewController;
        } while (parentViewController);
        if ([parentViewController isKindOfClass:%c(YTWatchViewController)])
            return [parentViewController valueForKeyPath:@"_videoID"];
    }
    YTPlayerViewController *pvc;
    NSObject *wc;
    @try {
        wc = [vc valueForKey:@"_metadataPanelStateProvider"];
    } @catch (id ex) {
        wc = [vc valueForKey:@"_ngwMetadataPanelStateProvider"];
    }
    @try {
        YTWatchPlaybackController *wpc = ((YTWatchController *)wc).watchPlaybackController;
        pvc = [wpc valueForKey:@"_playerViewController"];
    } @catch (id ex) {
        pvc = [wc valueForKey:@"_playerViewController"];
    }
    return [pvc contentVideoID];
}

static void getVoteAndModifyButtons(
    NSString *videoId,
    int pairMode,
    void (^likeHandler)(NSString *likeCount, NSNumber *likeNumber),
    void (^dislikeHandler)(NSString *dislikeCount, NSNumber *dislikeNumber)
) {
    getVoteFromVideoWithHandler(cache, videoId, maxRetryCount, ^(NSDictionary *data, NSString *error) {
        HBLogDebug(@"RYD: Vote data for video %@: %@", videoId, data);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ((ExactLikeNumber() || UseRYDLikeData()) && error == nil) {
                NSNumber *likeNumber = getLikeData(data);
                NSString *likeCount = getNormalizedLikes(likeNumber, nil);
                if (likeCount && likeHandler) {
                    HBLogDebug(@"RYD: Set like count for %@ to %@", videoId, likeCount);
                    likeHandler(likeCount, likeNumber);
                }
            }
            NSNumber *dislikeNumber = getDislikeData(data);
            NSString *dislikeCount = getNormalizedDislikes(dislikeNumber, error);
            if (dislikeHandler) {
                HBLogDebug(@"RYD: Set dislike count for %@ to %@", videoId, dislikeCount);
                dislikeHandler(dislikeCount, dislikeNumber);
            }
        });
    });
}

static YTCommonColorPalette *currentColorPalette() {
    Class YTPageStyleControllerClass = %c(YTPageStyleController);
    if (YTPageStyleControllerClass)
        return [YTPageStyleControllerClass currentColorPalette];
    YTAppDelegate *delegate = (YTAppDelegate *)[UIApplication sharedApplication].delegate;
    YTAppViewController *appViewController = [delegate valueForKey:@"_appViewController"];
    NSInteger pageStyle = [appViewController pageStyle];
    Class YTCommonColorPaletteClass = %c(YTCommonColorPalette);
    if (YTCommonColorPaletteClass)
        return pageStyle == 1 ? [YTCommonColorPaletteClass darkPalette] : [YTCommonColorPaletteClass lightPalette];
    return [%c(YTColorPalette) colorPaletteForPageStyle:pageStyle];
}

static void setTextColor(NSMutableAttributedString *text) {
    if (text == nil) return;
    UIColor *color = [currentColorPalette() textPrimary];
    [text addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, text.length)];
}

%hook ASCollectionView

%property (nonatomic, assign) BOOL hasDislikeIntent;
%property (nonatomic, assign) BOOL isProbablyVideoDescriptionHeaderPanel;

- (void)didMoveToWindow {
    %orig;
    if (self.window)
        self.isProbablyVideoDescriptionHeaderPanel = [[self _viewControllerForAncestor].navigationController isKindOfClass:%c(YTEngagementPanelNavigationController)];
}

- (ELMCellNode *)nodeForItemAtIndexPath:(NSIndexPath *)indexPath {
    ELMCellNode *node = %orig;
    if (!TweakEnabled()) return node;
    if (self.isProbablyVideoDescriptionHeaderPanel && isVideoDescriptionHeader(self, node)) {
        NSString *videoId = getVideoId(node);
        if (videoId == nil) return node;
        HBLogDebug(@"RYD: Found video description header");
        ELMContainerNode *rootContainerNode = [node.yogaChildren firstObject];
        ELMContainerNode *mainContainerNode = rootContainerNode.yogaChildren[1];
        ELMContainerNode *likeContainerNode = [mainContainerNode.yogaChildren firstObject];
        ELMContainerNode *rollingNumberContainerNode = [likeContainerNode.yogaChildren firstObject];

        if (rollingNumberContainerNode.yogaChildren.count == 1) {
            HBLogDebug(@"RYD: Appending dislike number to existing like number");
            infoLikeRollingNumberNode = [rollingNumberContainerNode.yogaChildren firstObject];
            id elementContext = [infoLikeRollingNumberNode valueForKey:@"_context"];
            overrideNodeCreation = 1;
            infoDislikeRollingNumberNode = [[%c(ELMNodeFactory) sharedInstance] nodeWithElement:infoLikeRollingNumberNode.element materializationContext:&elementContext];
            overrideNodeCreation = 0;
            infoDislikeRollingNumberNode.updatedCount = FETCHING;
            infoDislikeRollingNumberNode.updatedCountNumber = @(0);
            [infoDislikeRollingNumberNode updateRollingNumberView];
            [rollingNumberContainerNode addYogaChild:infoDislikeRollingNumberNode];
            [rollingNumberContainerNode.view addSubview:infoDislikeRollingNumberNode.view];

            self.hasDislikeIntent = YES;
            getVoteAndModifyButtons(
                videoId,
                -1,
                ^(NSString *likeCount, NSNumber *likeNumber) {
                    infoLikeRollingNumberNode.updatedCount = likeCount;
                    infoLikeRollingNumberNode.updatedCountNumber = likeNumber;
                    [infoLikeRollingNumberNode updateRollingNumberView];
                    [infoLikeRollingNumberNode relayoutNode];
                },
                ^(NSString *dislikeCount, NSNumber *dislikeNumber) {
                    infoDislikeRollingNumberNode.updatedCount = [NSString stringWithFormat:@"• %@", dislikeCount];
                    infoDislikeRollingNumberNode.updatedCountNumber = dislikeNumber;
                    [infoDislikeRollingNumberNode updateRollingNumberView];
                    [infoDislikeRollingNumberNode relayoutNode];
                }
            );
        }

        infoLikeTextNode = likeContainerNode.yogaChildren[1];
        if (![infoLikeTextNode.attributedText.string containsString:@"•"]) {
            NSMutableAttributedString *likeText = [[NSMutableAttributedString alloc] initWithAttributedString:infoLikeTextNode.attributedText]; 
            likeText.mutableString.string = [likeText.string stringByAppendingString:[NSString stringWithFormat:@" • %@", localizedDislikeText]];
            infoLikeTextNode.attributedText = likeText;
        }
    }
    else if (isVideoScrollableActionBar(self, node)) {
        /*
        Structure for the latest design
        No existing ELMTextNode to work with :(

        ELMContainerNode root
        |-ELMContainerNode
            |-ELMContainerNode
            |-ELMContainerNode
            |-ELMContainerNode id.video.non_scrollable_action_bar
                |-ELMContainerNode
                |-ELMContainerNode
                    |-ELMContainerNode id.video.like.button
                    |-ELMContainerNode
                        |-ELMContainerNode
                        |-ELMContainerNode
                            |-ELMAnimatedVectorNode
                |-ELMContainerNode
                |-ELMContainerNode
                    |-ELMContainerNode id.video.dislike.button
                    |-ELMImageNode
                |-ELMContainerNode
                |-ELMContainerNode
                |-ELMContainerNode
                |-ELMContainerNode
        */
        int pairMode = -1;
        BOOL isDislikeButtonModified = NO;
        ASDisplayNode *containerNode = node;
        ELMContainerNode *likeNode;

        if (![containerNode isKindOfClass:%c(ELMCellNode)]) {
            HBLogDebug(@"RYD: Container node is not ELMCellNode, instead found %@", containerNode);
            return node;
        }

        do {
            containerNode = [containerNode.yogaChildren firstObject];
            if (containerNode.yogaChildren.count == 2)
                containerNode = containerNode.yogaChildren[1];
        } while (containerNode.yogaChildren.count == 1);

        likeNode = [containerNode.yogaChildren firstObject];
        if (![likeNode.accessibilityIdentifier isEqualToString:@"id.video.like.button"]) {
            HBLogDebug(@"RYD: Like button not found, instead found %@", likeNode.accessibilityIdentifier);
            return node;
        }

        NSString *videoId = getVideoId(node);
        if (videoId == nil) return node;
        if (likeNode.yogaChildren.count == 2) {
            ELMContainerNode *dislikeNode = [containerNode.yogaChildren lastObject];
            isDislikeButtonModified = dislikeNode.yogaChildren.count == 2;
            id targetNode = likeNode.yogaChildren[1];
            if ([targetNode isKindOfClass:%c(YTRollingNumberNode)]) {
                likeRollingNumberNode = (YTRollingNumberNode *)targetNode;
                if (isDislikeButtonModified)
                    dislikeRollingNumberNode = dislikeNode.yogaChildren[1];
                else {
                    id elementContext = [likeRollingNumberNode valueForKey:@"_context"];
                    overrideNodeCreation = 1;
                    dislikeRollingNumberNode = [[%c(ELMNodeFactory) sharedInstance] nodeWithElement:likeRollingNumberNode.element materializationContext:&elementContext];
                    overrideNodeCreation = 0;
                    dislikeRollingNumberNode.updatedCount = FETCHING;
                    dislikeRollingNumberNode.updatedCountNumber = @(0);
                    [dislikeRollingNumberNode updateRollingNumberView];
                    [dislikeNode addYogaChild:dislikeRollingNumberNode];
                    [dislikeNode.view addSubview:dislikeRollingNumberNode.view];
                    pairMode = 0;
                }
            } else if ([targetNode isKindOfClass:%c(ELMTextNode)]) {
                likeTextNode = (ELMTextNode *)targetNode;
                if (isDislikeButtonModified)
                    dislikeTextNode = dislikeNode.yogaChildren[1];
                else {
                    id elementContext = [likeTextNode valueForKey:@"_context"];
                    overrideNodeCreation = 2;
                    dislikeTextNode = [[%c(ELMNodeFactory) sharedInstance] nodeWithElement:likeTextNode.element materializationContext:&elementContext];
                    overrideNodeCreation = 0;
                    mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
                    dislikeTextNode.attributedText = mutableDislikeText;
                    [dislikeNode addYogaChild:dislikeTextNode];
                    [dislikeNode.view addSubview:dislikeTextNode.view];
                    pairMode = 0;
                }
            }
        } else {
            dislikeTextNode = likeNode.yogaChildren[1];
            if (![dislikeTextNode isKindOfClass:%c(ELMTextNode)]) {
                HBLogDebug(@"RYD: Dislike button not found, instead found %@", dislikeTextNode);
                return node;
            }
            mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:dislikeTextNode.attributedText];
            mutableDislikeText.mutableString.string = FETCHING;
            dislikeTextNode.attributedText = mutableDislikeText;
        }
        self.hasDislikeIntent = YES;
        BOOL shouldFetchVote = (ExactLikeNumber() || UseRYDLikeData()) || !isDislikeButtonModified;
        if (shouldFetchVote) {
            getVoteAndModifyButtons(
                videoId,
                pairMode,
                ^(NSString *likeCount, NSNumber *likeNumber) {
                    if (likeRollingNumberNode) {
                        likeRollingNumberNode.updatedCount = likeCount;
                        likeRollingNumberNode.updatedCountNumber = likeNumber;
                        [likeRollingNumberNode updateRollingNumberView];
                        [likeRollingNumberNode relayoutNode];
                    } else {
                        NSMutableAttributedString *mutableLikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
                        mutableLikeText.mutableString.string = likeCount;
                        setTextColor(mutableLikeText);
                        likeTextNode.attributedText = mutableLikeText;
                        likeTextNode.accessibilityLabel = likeCount;
                    }
                },
                ^(NSString *dislikeCount, NSNumber *dislikeNumber) {
                    if (isDislikeButtonModified) return;
                    NSString *dislikeString;
                    switch (pairMode) {
                        case -1:
                            dislikeString = dislikeCount;
                            break;
                        case 0:
                            dislikeString = [NSString stringWithFormat:@"  %@ ", dislikeCount];
                            break;
                    }
                    if (dislikeRollingNumberNode) {
                        dislikeRollingNumberNode.updatedCount = dislikeString;
                        dislikeRollingNumberNode.updatedCountNumber = dislikeNumber;
                        [dislikeRollingNumberNode updateRollingNumberView];
                        [dislikeRollingNumberNode relayoutNode];
                    } else {
                        mutableDislikeText.mutableString.string = dislikeString;
                        setTextColor(mutableDislikeText);
                        dislikeTextNode.attributedText = mutableDislikeText;
                        dislikeTextNode.accessibilityLabel = dislikeCount;
                    }
                }
            );
        }
    }
    return node;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    if (!self.hasDislikeIntent || TweakEnabled()) return;
    if (dislikeRollingNumberNode) {
        YTRollingNumberView *likeView = [likeRollingNumberNode valueForKey:@"_rollingNumberView"];
        [dislikeRollingNumberNode updateCount:dislikeRollingNumberNode.updatedCount color:likeView.color];
    }
    if (infoDislikeRollingNumberNode) {
        YTRollingNumberView *likeView = [infoLikeRollingNumberNode valueForKey:@"_rollingNumberView"];
        [infoDislikeRollingNumberNode updateCount:infoDislikeRollingNumberNode.updatedCount color:likeView.color];
    }
    if (dislikeTextNode) {
        NSString *dislikeText = dislikeTextNode.attributedText.string;
        mutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:likeTextNode.attributedText];
        mutableDislikeText.mutableString.string = dislikeText;
        dislikeTextNode.attributedText = mutableDislikeText;
    }
    if (infoLikeTextNode) {
        NSString *likeDislikeText = infoLikeTextNode.attributedText.string;
        NSMutableAttributedString *mutableInfoLikeDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:infoLikeTextNode.attributedText];
        mutableInfoLikeDislikeText.mutableString.string = likeDislikeText;
        infoLikeTextNode.attributedText = mutableInfoLikeDislikeText;
    }
}

%end

static void setTextNodeColor(ELMTextNode *node, UIColor *color) {
    if (node == nil) return;
    NSString *text = node.attributedText.string;
    NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{ NSForegroundColorAttributeName: color }];
    node.attributedText = attributedText;
}

%hook YTAsyncCollectionView

- (void)pageStyleDidChange:(NSInteger)pageStyle {
    %orig;
    if (![self.pageStylingDelegate isKindOfClass:%c(YTWatchNextResultsViewController)]) return;
    YTCommonColorPalette *colorPalette = currentColorPalette();
    UIColor *textColor = [colorPalette textPrimary];
    setTextNodeColor(likeTextNode, textColor);
    setTextNodeColor(dislikeTextNode, textColor);
}

%end

static void layoutActionBar(YTReelWatchPlaybackOverlayView *self) {
    if (!TweakEnabled() || self.didGetVote) return;
    id spvc = [self parentResponder];
    YTReelModel *model = [spvc valueForKey:@"_model"];
    NSString *videoId;
    @try {
        videoId = [model endpoint].reelWatchEndpoint.videoId;
    } @catch (id ex) {
        videoId = [model command].reelWatchEndpoint.videoId;
        if (videoId.length == 0 && [spvc isKindOfClass:%c(YTShortsPlayerViewController)])
            videoId = [[[(YTShortsPlayerViewController *)spvc currentVideo] singleVideo] videoId];
    }
    HBLogDebug(@"RYD: Short ID: %@", videoId);
    if (videoId == nil) return;
    YTELMView *elmView = nil;
    @try {
        elmView = [self valueForKey:@"_actionBarView"];
    } @catch (id ex) {}
    if (elmView == nil) {
        @try {
            YTReelElementAsyncComponentView *view = [self valueForKey:@"_actionBarComponentView"];
            elmView = [view valueForKey:@"_elementView"];
        } @catch (id ex) {}
    }
    BOOL isNested = NO;
    if (elmView == nil) {
        @try {
            YTReelElementAsyncComponentView *playerOverlayView = [self valueForKey:@"_playerOverlayView"];
            elmView = [playerOverlayView valueForKey:@"_elementView"];
            isNested = YES;
        } @catch (id ex) {}
    }
    if (elmView == nil) return;
    if ([elmView isKindOfClass:%c(YTReelWatchActionBarView)])
        elmView = [elmView valueForKey:@"_actionBarElement"];
    ELMContainerNode *containerNode;
    if (isNested) {
        ELMContainerNode *node = [elmView valueForKey:@"_rootNode"];
        node = [node.yogaChildren firstObject];
        containerNode = [node.yogaChildren yt_objectAtIndexOrNil:1];
    } else
        containerNode = [elmView valueForKey:@"_rootNode"];
    ELMContainerNode *likeNode = [containerNode.yogaChildren firstObject];
    ELMContainerNode *dislikeNode = [containerNode.yogaChildren yt_objectAtIndexOrNil:1];
    BOOL foundLikeButton = NO;
    BOOL foundDislikeButton = NO;
    @try {
        ELMComponent *likeOwningComponent = [[likeNode controller] owningComponent];
        if ([likeOwningComponent owningComponent]) likeOwningComponent = [likeOwningComponent owningComponent];
        foundLikeButton = [[likeOwningComponent templateURI] hasPrefix:@"reel_like_button"];
        ELMComponent *dislikeOwningComponent = [[dislikeNode controller] owningComponent];
        if ([dislikeOwningComponent owningComponent]) dislikeOwningComponent = [dislikeOwningComponent owningComponent];
        foundDislikeButton = [[dislikeOwningComponent templateURI] hasPrefix:@"reel_dislike_button"];
    } @catch (id ex) {
        HBLogDebug(@"RYD: Error checking if like/dislike button is found: %@", ex);
    }
    if (!foundLikeButton) {
        do {
            likeNode = [likeNode.yogaChildren firstObject];
        } while ([likeNode.accessibilityIdentifier isEqualToString:@"id.reel_like_button"]);
        do {
            likeNode = [likeNode.yogaChildren firstObject];
        } while (likeNode.yogaChildren.count == 1);
    }
    if (!foundDislikeButton) {
        do {
            dislikeNode = [dislikeNode.yogaChildren firstObject];
        } while ([dislikeNode.accessibilityIdentifier isEqualToString:@"id.reel_dislike_button"]);
        do {
            dislikeNode = [dislikeNode.yogaChildren firstObject];
        } while (dislikeNode.yogaChildren.count == 1);
    }
    NSArray *likeChildren = likeNode.yogaChildren;
    if (likeChildren.count == 1) likeChildren = ((ASDisplayNode *)[likeNode.yogaChildren firstObject]).yogaChildren;
    ELMTextNode *shortLikeTextNode = [likeChildren yt_objectAtIndexOrNil:1];
    NSArray *dislikeChildren = dislikeNode.yogaChildren;
    if (dislikeChildren.count == 1) dislikeChildren = ((ASDisplayNode *)[dislikeNode.yogaChildren firstObject]).yogaChildren;
    ELMTextNode *shortDislikeTextNode = [dislikeChildren yt_objectAtIndexOrNil:1];
    if (shortLikeTextNode == nil || shortDislikeTextNode == nil || ![shortLikeTextNode isKindOfClass:%c(ELMTextNode)] || ![shortDislikeTextNode isKindOfClass:%c(ELMTextNode)]) {
        HBLogDebug(@"RYD: Short like or dislike text node not found");
        return;
    }
    __block NSMutableAttributedString *shortMutableDislikeText = [[NSMutableAttributedString alloc] initWithAttributedString:shortLikeTextNode.attributedText];
    shortMutableDislikeText.mutableString.string = FETCHING;
    shortDislikeTextNode.attributedText = shortMutableDislikeText;
    getVoteAndModifyButtons(
        videoId,
        -1,
        ^(NSString *likeCount, NSNumber *likeNumber) {
            NSMutableAttributedString *shortMutableLikeText = [[NSMutableAttributedString alloc] initWithAttributedString:shortLikeTextNode.attributedText];
            shortMutableLikeText.mutableString.string = likeCount;
            shortLikeTextNode.attributedText = shortMutableLikeText;
            shortLikeTextNode.accessibilityLabel = likeCount;
        },
        ^(NSString *dislikeCount, NSNumber *dislikeNumber) {
            shortMutableDislikeText.mutableString.string = dislikeCount;
            shortDislikeTextNode.attributedText = shortMutableDislikeText;
            shortDislikeTextNode.accessibilityLabel = dislikeCount;
        }
    );
    self.didGetVote = YES;
}

%hook YTReelWatchPlaybackOverlayView

%property (assign, nonatomic) BOOL didGetVote;

- (void)layoutActionBar {
    %orig;
    layoutActionBar(self);
}

%end

%hook YTReelWatchPlaybackOverlayViewSub

%property (assign, nonatomic) BOOL didGetVote;

- (void)layoutActionBar {
    %orig;
    layoutActionBar((YTReelWatchPlaybackOverlayView *)self);
}

%end

%hook YTRollingNumberNode

%property (strong, nonatomic) NSString *updatedCount;
%property (strong, nonatomic) NSNumber *updatedCountNumber;

- (id)initWithElement:(id)element context:(id)context {
    self = %orig;
    if (self) {
        self.updatedCount = nil;
        self.updatedCountNumber = nil;
    }
    return self;
}

- (void)updateRollingNumberView {
    %orig;
    if (self.updatedCount && self.updatedCountNumber)
        [self updateCount:self.updatedCount color:nil];
}

%new(v@:@@)
- (void)updateCount:(NSString *)updatedCount_ color:(UIColor *)color_ {
    YTRollingNumberView *view = [self valueForKey:@"_rollingNumberView"];
    UIFont *font = view.font;
    UIColor *color = color_ ?: view.color;
    NSString *updatedCount = [NSString stringWithFormat:@" %@", updatedCount_];
    if ([view respondsToSelector:@selector(setUpdatedCount:updatedCountNumber:font:fontAttributes:color:skipAnimation:)])
        [view setUpdatedCount:updatedCount updatedCountNumber:self.updatedCountNumber font:font fontAttributes:view.fontAttributes color:color skipAnimation:YES];
    else
        [view setUpdatedCount:updatedCount updatedCountNumber:self.updatedCountNumber font:font color:color skipAnimation:YES];
}

%end

%hook ELMNodeFactory

- (Class)classForElement:(id)element materializationContext:(const void *)context {
    switch (overrideNodeCreation) {
        case 1:
            return %c(YTRollingNumberNode);
        case 2:
            return %c(ELMTextNode);
        default:
            return %orig;
    }
}

%end

// ---------------------------------------------------------------------------
// Native action bar (YouTube 21.x "details actions" design)
// ---------------------------------------------------------------------------
//
// Everything above this point assumes the like/dislike row is rendered by
// Elements, and reaches it through ASCollectionView -nodeForItemAtIndexPath:.
// On the current watch page that is no longer true. The row under the video is
// YTSlimVideoScrollableDetailsActionsView -- a plain UIView that builds native
// YTSlimVideoDetailsActionView children in -createActionViewsFromSupportedRenderers:
// and keeps the two we care about in the _likeActionView / _dislikeActionView
// ivars. No ELMCellNode is ever created for it, so the Elements hook simply
// never fires and the row renders with no counts at all.
//
// Each action view owns a YTFormattedStringLabel (_label) beside its button.
// YouTube leaves it empty in this design -- it moved the like count up into the
// metadata line -- so writing the dislike count into the dislike view's label
// is enough, and it lands exactly where the count used to be.

// Both classes are already declared in YouTubeHeader (imported via Tweak.h), so
// this is a category for the %new/%property additions rather than a redeclaration.
@interface YTSlimVideoDetailsActionView (RYD)
@property (nonatomic, strong) NSString *rydVideoId;
@property (nonatomic, strong) NSString *rydDislikeText;
- (void)ryd_applyDislikeText;
- (void)ryd_fetchDislikes;
@end

// Arbitrary, just needs to not collide with YouTube's own view tags.
static const NSInteger RYDDislikeLabelTag = 0x52594444;

// The Elements path gets its video ID from the node's closest view controller.
// A native view has no node, so walk the responder chain instead -- same
// destination (YTWatchViewController's _videoID), different route in.
static NSString *videoIdFromResponderChain(UIView *view) {
    UIResponder *responder = view;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:%c(YTWatchViewController)]) {
            @try {
                return [responder valueForKey:@"_videoID"];
            } @catch (__unused id ex) {
                return nil;
            }
        }
    }
    return nil;
}

// Hook the button, not the bar.
//
// Two earlier attempts went through the container
// (YTSlimVideoScrollableDetailsActionsView, reached via its
// id.video.detailsactions.view identifier) and neither rendered anything. The
// container is the wrong thing to depend on: YouTube ships more than one action
// bar implementation -- an Elements-rendered one and a native one, seemingly
// A/B tested -- so whichever container is hooked, it may simply not be the one
// in use, and the hook never fires.
//
// The individual button is the stable part. YTSlimVideoDetailsActionView tags
// itself id.video.dislike.button in -updateAccessibilityIdentifier, which is
// set by the time it lays out, so matching on that finds the dislike button
// wherever it is hosted and regardless of what built it.
%hook YTSlimVideoDetailsActionView

%property (nonatomic, strong) NSString *rydVideoId;
%property (nonatomic, strong) NSString *rydDislikeText;

%new
- (void)ryd_applyDislikeText {
    if (self.rydDislikeText.length == 0) return;

    CGRect bounds = self.bounds;
    if (bounds.size.height <= 0 || bounds.size.width <= 0) return;

    // Do not reuse the view's own _label. In this design YouTube ships the
    // action bar with no counts at all -- the like count moved up to the
    // metadata line -- so that label is empty, and an empty label is not
    // something -layoutSubviews is obliged to position or even keep in the
    // hierarchy. Writing into it and hoping YouTube lays it out is how the
    // previous attempt failed silently. Own the label instead.
    UILabel *label = (UILabel *)[self viewWithTag:RYDDislikeLabelTag];
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = RYDDislikeLabelTag;
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        label.userInteractionEnabled = NO;
        label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [self addSubview:label];
    }

    // Not +labelColor: this tweak deploys to iOS 11 and that is 13+. The
    // palette is YouTube's own text colour and already follows the theme.
    label.textColor = [currentColorPalette() textPrimary] ?: [UIColor whiteColor];
    if (![label.text isEqualToString:self.rydDislikeText])
        label.text = self.rydDislikeText;

    // These buttons are icon-sized and centred, so the count goes just below
    // the glyph. clipsToBounds is cleared because the label may need the last
    // couple of points below the view to stay legible.
    self.clipsToBounds = NO;
    CGFloat height = 13.0;
    label.frame = CGRectMake(-4.0, bounds.size.height - height, bounds.size.width + 8.0, height);
    [self bringSubviewToFront:label];
}

%new
- (void)ryd_fetchDislikes {
    NSString *videoId = videoIdFromResponderChain(self);
    if (videoId.length == 0) return;
    // Action views are reused as the watch page moves between videos, so only
    // refetch when the video actually changed.
    if ([self.rydVideoId isEqualToString:videoId]) return;

    self.rydVideoId = videoId;
    self.rydDislikeText = FETCHING;
    [self ryd_applyDislikeText];

    __weak typeof(self) weakSelf = self;
    getVoteAndModifyButtons(videoId, -1, nil, ^(NSString *dislikeCount, __unused NSNumber *dislikeNumber) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        // A slow response for the previous video must not overwrite the
        // current one's count.
        if (!strongSelf || ![strongSelf.rydVideoId isEqualToString:videoId]) return;
        strongSelf.rydDislikeText = dislikeCount;
        [strongSelf ryd_applyDislikeText];
    });
}

- (void)layoutSubviews {
    %orig;
    if (!TweakEnabled()) return;
    if (![self.accessibilityIdentifier isEqualToString:@"id.video.dislike.button"]) return;

    [self ryd_fetchDislikes];
    [self ryd_applyDislikeText];
}

%end

%ctor {
    cache = [NSCache new];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:DidShowEnableVoteSubmissionAlertKey] && !VoteSubmissionEnabled()) {
        [defaults setBool:YES forKey:DidShowEnableVoteSubmissionAlertKey];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSBundle *tweakBundle = RYDBundle();
            YTAlertView *alertView = [%c(YTAlertView) confirmationDialogWithAction:^{
                enableVoteSubmission(YES);
            } actionTitle:_LOC([NSBundle mainBundle], @"settings.yes")];
            alertView.title = @(TWEAK_NAME);
            alertView.subtitle = [NSString stringWithFormat:LOC(@"WANT_TO_ENABLE"), @(API_URL), alertView.title, LOC(@"ENABLE_VOTE_SUBMIT")];
            [alertView show];
        });
    }
    [[NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Frameworks/Module_Framework.framework", NSBundle.mainBundle.bundlePath]] load];
    localizedDislikeText = _LOC([NSBundle mainBundle], @"offline.dislike");
    %init;
}
