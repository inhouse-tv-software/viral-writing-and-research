//
//  BeatTextView+MouseEvents.m
//  Beat macOS
//
//  Created by Lauri-Matti Parppei on 7.7.2025.
//  Copyright © 2025 Lauri-Matti Parppei. All rights reserved.
//

#import "BeatTextView+MouseEvents.h"
#import "BeatTextView+Popovers.h"
#import <QuartzCore/QuartzCore.h>

@implementation BeatTextView (MouseEvents)


#pragma mark - Mouse events

// Viral: the scrollWheel: override that used to be here turned off macOS responsive (threaded) scrolling for the
// whole editor. The `scrolling` flag is now set from the scroll view's live scroll notifications (see BeatTextView setup).

/// Viral: pinching on the trackpad zooms into the page like a picture while your fingers are down, and springs back when
/// you let go. Nothing is re-laid out: the text, widths and settings don't change. (Use the Aa panel for a bigger text size.)
- (void)magnifyWithEvent:(NSEvent *)event
{
	static CGFloat scale = 1.0;
	static CGPoint anchor;
	
	NSView* frameView = self.enclosingScrollView.superview;
	if (frameView == nil) return;
	frameView.wantsLayer = YES;
	CALayer* layer = frameView.layer;
	
	if (event.phase == NSEventPhaseBegan || scale <= 1.0) {
		NSPoint p = [frameView convertPoint:event.locationInWindow fromView:nil];
		// sublayerTransform works around the layer's anchor point
		anchor = CGPointMake(p.x - layer.bounds.size.width * layer.anchorPoint.x, p.y - layer.bounds.size.height * layer.anchorPoint.y);
	}
	
	if (event.phase == NSEventPhaseEnded || event.phase == NSEventPhaseCancelled) {
		CABasicAnimation* back = [CABasicAnimation animationWithKeyPath:@"sublayerTransform"];
		back.fromValue = [NSValue valueWithCATransform3D:layer.sublayerTransform];
		back.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
		back.duration = 0.25;
		back.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
		layer.sublayerTransform = CATransform3DIdentity;
		[layer addAnimation:back forKey:@"viralZoomBack"];
		scale = 1.0;
		return;
	}
	
	scale = MIN(MAX(scale * (1.0 + event.magnification), 1.0), 4.0);
	CATransform3D t = CATransform3DMakeTranslation(anchor.x, anchor.y, 0);
	t = CATransform3DScale(t, scale, scale, 1.0);
	t = CATransform3DTranslate(t, -anchor.x, -anchor.y, 0);
	
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	[layer removeAnimationForKey:@"viralZoomBack"];
	layer.sublayerTransform = t;
	[CATransaction commit];
}


- (void)mouseDown:(NSEvent *)event
{
	[super mouseDown:event];
	[self closePopovers];
}

- (void)mouseUp:(NSEvent *)event
{
	[super mouseUp:event];
}

- (void)otherMouseUp:(NSEvent *)event
{
	// We'll use buttons 3/4 to navigate between scenes
	switch (event.buttonNumber) {
		case 3:
			[self.editorDelegate nextScene:self];
			return;
		case 4:
			[self.editorDelegate previousScene:self];
			return;
		default:
			break;
	}
	
	[super otherMouseUp:event];
}

- (void)mouseMoved:(NSEvent *)event
{
	// point in this scaled text view
	NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
	
	// point in unscaled parent view
	NSPoint superviewPoint = [self.enclosingScrollView convertPoint:event.locationInWindow fromView:nil];
	
	// y position in window
	CGFloat y = event.locationInWindow.y;
	
	// Super cursor when inside the text container, otherwise arrow
	if (self.window.isKeyWindow) {
		CGFloat leftX = self.textContainerInset.width + BeatTextView.linePadding;
		CGFloat rightX = (self.textContainer.size.width + self.textContainerInset.width - BeatTextView.linePadding) * (1/self.zoomLevel);
		
		if ((point.x > leftX && point.x * (1/self.zoomLevel) < rightX) &&
			y < self.window.frame.size.height - 22 &&
			superviewPoint.y < self.enclosingScrollView.frame.size.height) {
			//[super mouseMoved:event];
			[NSCursor.IBeamCursor set];
		} else if (point.x > 10) {
			[NSCursor.arrowCursor set];
		}
	}
}

-(void)resetCursorRects
{
	[super resetCursorRects];
}

-(void)cursorUpdate:(NSEvent *)event
{
	[NSCursor.IBeamCursor set];
}


@end
