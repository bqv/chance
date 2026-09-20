import 'dart:async';
import 'dart:ui';

import 'package:chan/models/attachment.dart';
import 'package:chan/services/apple.dart';
import 'package:chan/services/attachment_cache.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/network_image_provider.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/services/theme.dart';
import 'package:chan/services/thumbnailer.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/adaptive.dart';
import 'package:chan/widgets/attachment_viewer.dart';
import 'package:chan/widgets/one_frame_image_provider.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/util.dart';
import 'package:flutter/cupertino.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class TaggedAttachment {
	final Imageboard imageboard;
	final Attachment attachment;
	final Iterable<int> semanticParentIds;
	final int postId;
	final String _tag;
	TaggedAttachment({
		required this.imageboard,
		required this.attachment,
		required this.semanticParentIds,
		required this.postId
	}) : _tag = '${imageboard.key}/${semanticParentIds.join('/')}/$postId/${attachment.id}';

	@override
	bool operator == (Object other) {
		if (identical(this, other)) {
			return true;
		}
		return (other is TaggedAttachment) && _tag == other._tag;
	}

	@override
	int get hashCode {
		return _tag.hashCode;
	}

	@override
	String toString() => 'AttachmentSemanticLocation($_tag)';
}

class AttachmentThumbnailCornerIcon {
	final Color backgroundColor;
	final Color borderColor;
	final double? size;
	final TextSpan? appendText;
	final Alignment alignment;

	const AttachmentThumbnailCornerIcon({
		required this.backgroundColor,
		required this.borderColor,
		this.size,
		this.appendText,
		this.alignment = Alignment.bottomRight
	});
}

typedef _AfterPaintKey = (Attachment, AttachmentThumbnailCornerIcon);
typedef _AfterPaint = void Function(Canvas canvas, Rect rect);
typedef _KeyedAfterPaint = ({_AfterPaintKey key, _AfterPaint afterPaint});

_KeyedAfterPaint? _makeKeyedAfterPaint({
	required Attachment attachment,
	required AttachmentThumbnailCornerIcon? cornerIcon,
	required IconData? alreadyShowingBigIcon,
	required Color primaryColor
}) {
	if (cornerIcon == null || ((attachment.icon == null || attachment.icon == alreadyShowingBigIcon) && cornerIcon.appendText == null)) {
		return null;
	}
	return (
		key: (attachment, cornerIcon),
		afterPaint: (canvas, rect) {
			final icon = attachment.icon;
			final appendText = cornerIcon.appendText;
			if ((icon == null || icon == alreadyShowingBigIcon) && appendText == null) {
				// Nothing to draw
				return;
			}
			final fontSize = cornerIcon.size ?? 16;
			TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr);
			textPainter.text = TextSpan(
				children: [
					if (icon != null && icon != alreadyShowingBigIcon) IconSpan(
						icon: icon,
						size: fontSize,
						color: primaryColor
					),
					if (icon != null && appendText != null) const TextSpan(text: ' '),
					if (appendText != null) appendText
				]
			);
			textPainter.layout();
			final badgeSize = EdgeInsets.all(fontSize / 4).inflateSize(textPainter.size);
			final badgeRect = cornerIcon.alignment.inscribe(badgeSize, rect);
			final rrect = RRect.fromRectAndCorners(
				badgeRect,
				topLeft: cornerIcon.alignment == Alignment.bottomRight ? Radius.circular(fontSize * 0.375) : Radius.zero,
				topRight: cornerIcon.alignment == Alignment.bottomLeft ? Radius.circular(fontSize * 0.375) : Radius.zero,
				bottomLeft: cornerIcon.alignment == Alignment.topRight ? Radius.circular(fontSize * 0.375) : Radius.zero,
				bottomRight: cornerIcon.alignment == Alignment.topLeft ? Radius.circular(fontSize * 0.375) : Radius.zero
			);
			canvas.drawRRect(rrect, Paint()
				..color = cornerIcon.backgroundColor
				..style = PaintingStyle.fill);
			canvas.drawRRect(rrect, Paint()
				..strokeWidth = 1
				..color = cornerIcon.borderColor
				..style = PaintingStyle.stroke);
			textPainter.paint(canvas, Alignment.center.inscribe(textPainter.size, badgeRect).topLeft + const Offset(1, 1));
		}
	);
}

class AttachmentThumbnail extends StatelessWidget {
	final Attachment attachment;
	final double? width;
	final double? height;
	final BoxFit fit;
	final Object? hero;
	final bool rotate90DegreesClockwise;
	final Function(Object?, StackTrace?)? onLoadError;
	final Alignment alignment;
	final bool gaplessPlayback;
	final bool revealSpoilers;
	final ImageboardSite? site;
	final bool shrinkHeight;
	final bool? overrideFullQuality;
	/// Whether it is actually a thumbnail (preview) like in catalog/thread
	final bool mayObscure;
	final AttachmentThumbnailCornerIcon? cornerIcon;
	final bool expand;
	final bool hide;
	final bool suppressImageRebuild;

	const AttachmentThumbnail({
		required this.attachment,
		this.width,
		this.height,
		this.fit = BoxFit.contain,
		this.alignment = Alignment.center,
		this.hero,
		this.rotate90DegreesClockwise = false,
		this.onLoadError,
		this.gaplessPlayback = false,
		this.revealSpoilers = false,
		this.shrinkHeight = false,
		this.site,
		this.overrideFullQuality,
		this.cornerIcon,
		this.expand = false,
		this.hide = false,
		this.suppressImageRebuild = false,
		required this.mayObscure,
		Key? key
	}) : super(key: key);

	Widget _maybeHero(BuildContext context, Widget child) {
		return (hero != null) ? Hero(
			tag: hero!,
			child: child,
			flightShuttleBuilder: (context, animation, direction, fromContext, toContext) {
				return (direction == HeroFlightDirection.push ? fromContext.widget as Hero : toContext.widget as Hero).child;
			},
			createRectTween: (startRect, endRect) {
				if (startRect != null && endRect != null) {
					if (attachment.type == AttachmentType.image || attachment.type.isVideo) {
						// Need to deflate the original startRect because it has inbuilt layoutInsets
						// This AttachmentThumbnail will always fill its size
						final rootPadding = MediaQueryData.fromView(View.of(context)).padding - sumAdditionalSafeAreaInsets();
						startRect = rootPadding.deflateRect(startRect);
					}
					if (fit == BoxFit.cover && attachment.width != null && attachment.height != null) {
						// This is AttachmentViewer -> AttachmentThumbnail (cover)
						// Need to shrink the startRect, so it only contains the image
						final fittedStartSize = applyBoxFit(BoxFit.contain, Size(attachment.width!.toDouble(), attachment.height!.toDouble()), startRect.size).destination;
						startRect = Alignment.center.inscribe(fittedStartSize, startRect);
					}
				}
				return CurvedRectTween(curve: Curves.ease, begin: startRect, end: endRect);
			}
		) : child;
	}

	Widget _build({
		required BuildContext context,
		required Settings settings,
		required double effectiveWidth,
		required double effectiveHeight,
		required bool forceFullQuality
	}) {
		final spoiler = attachment.spoiler && !revealSpoilers;
		final s = site ?? context.watch<ImageboardSite?>();
		if (s == null) {
			return SizedBox(
				width: effectiveWidth,
				height: effectiveHeight,
				child: const Center(
					child: Icon(CupertinoIcons.exclamationmark_triangle_fill)
				)
			);
		}
		bool resize = false;
		String url = attachment.thumbnailUrl;
		if ((
			forceFullQuality ||
			(overrideFullQuality ?? (settings.fullQualityThumbnails && !attachment.isRateLimited))
		) && attachment.type == AttachmentType.image) {
			resize = true;
			url = attachment.url;
		}
		// A site may publish a file before the thumbnail variant of it exists (a
		// fresh upload can be transcoded to another format before it is
		// thumbnailed), so the full-size image can stand in for a preview which
		// will not load.
		String? previewFallbackUrl = (attachment.type == AttachmentType.image && overrideFullQuality != false) ? attachment.url : null;
		if (spoiler && !settings.alwaysShowSpoilers) {
			url = s.getSpoilerImageUrl(
				attachment,
				thread: context.read<PostSpanZoneData?>()?.primaryThreadState?.thread
			)?.toString() ?? '';
			// Never reveal the real image through a failed spoiler thumbnail
			previewFallbackUrl = null;
		}
		if (url.isEmpty) {
			final icon = spoiler ? CupertinoIcons.eye_slash : (attachment.icon ?? Adaptive.icons.photo);
			final theme = context.watch<SavedTheme>();
			return _maybeHero(context, SizedBox(
				width: effectiveWidth,
				height: shrinkHeight || expand ? null : effectiveHeight,
				child: _AttachmentThumbnailPlaceholder(
					child: null,
					icon: icon,
					effectiveWidth: effectiveWidth,
					effectiveHeight: effectiveHeight,
					attachment: attachment,
					afterPaint: _makeKeyedAfterPaint(
						attachment: attachment,
						cornerIcon: AttachmentThumbnailCornerIcon(
							backgroundColor: theme.backgroundColor,
							borderColor: theme.primaryColorWithBrightness(0.2),
							size: null
						),
						alreadyShowingBigIcon: icon,
						primaryColor: ChanceTheme.primaryColorOf(context)
					),
					fit: fit
				)
			));
		}
		final primaryColor = ChanceTheme.primaryColorOf(context);
		final cornerIcon = this.cornerIcon;
		_KeyedAfterPaint? makeAfterPaint({IconData? alreadyShowingBigIcon}) =>
			_makeKeyedAfterPaint(attachment: attachment, cornerIcon: cornerIcon, alreadyShowingBigIcon: alreadyShowingBigIcon, primaryColor: primaryColor);
		Widget child;
		if (settings.loadThumbnails && !hide) {
			final VoidCallback? onFullQualityLoaded = url == attachment.url ? () {
				if (!forceFullQuality) {
					// Forced thumbnails are already known to be cached, don't report it
					AttachmentCache.onCached(attachment, this);
				}
			} : null;
			child = _RetryingPreviewImage(
				url: url,
				fallbackUrl: previewFallbackUrl,
				builder: (context, effectiveUrl, isFallback, retryGeneration, onLoadFailed) => _buildImage(
					context: context,
					settings: settings,
					site: s,
					effectiveWidth: effectiveWidth,
					effectiveHeight: effectiveHeight,
					fit: fit,
					url: effectiveUrl,
					isFallback: isFallback,
					retryGeneration: retryGeneration,
					resize: resize,
					afterFirstLoad: onFullQualityLoaded,
					onLoadFailed: onLoadFailed
				)
			);
		}
		else {
			final icon = attachment.icon ?? Adaptive.icons.photo;
			child = _AttachmentThumbnailPlaceholder(
				child: null,
				icon: icon,
				effectiveWidth: effectiveWidth,
				effectiveHeight: effectiveHeight,
				attachment: attachment,
				afterPaint: makeAfterPaint(alreadyShowingBigIcon: icon),
				fit: fit
			);
		}
		return _maybeHero(context, child);
	}

	/// Builds the image which loads [url] for this thumbnail.
	///
	/// [isFallback] is true when [url] is the attachment's full-size image,
	/// loaded because the thumbnail variant of it was not available.
	Widget _buildImage({
		required BuildContext context,
		required Settings settings,
		required ImageboardSite site,
		required double effectiveWidth,
		required double effectiveHeight,
		required BoxFit fit,
		required String url,
		required bool isFallback,
		required int retryGeneration,
		required bool resize,
		required VoidCallback? afterFirstLoad,
		required VoidCallback onLoadFailed
	}) {
		final primaryColor = ChanceTheme.primaryColorOf(context);
		_KeyedAfterPaint? makeAfterPaint({IconData? alreadyShowingBigIcon}) =>
			_makeKeyedAfterPaint(attachment: attachment, cornerIcon: cornerIcon, alreadyShowingBigIcon: alreadyShowingBigIcon, primaryColor: primaryColor);
		final uri = Uri.parse(url);
		ImageProvider image = CNetworkImageProvider(
			url,
			client: site.client,
			cache: true,
			headers: {
				...site.getHeaders(attachment, uri),
				if (attachment.useRandomUseragent) 'user-agent': makeRandomUserAgent()
			},
			afterFirstLoad: afterFirstLoad
		);
		if (url.endsWith('.gif') || url.endsWith('.webp') /* might be animated WebP */) {
			image = OneFrameImageProvider(image);
		}
		final pixelation = settings.thumbnailPixelation;
		final FilterQuality filterQuality;
		if (pixelation > 0 && mayObscure) {
			filterQuality = FilterQuality.none;
			// In BoxFit.cover we see the shortest side
			final targetLongestSide = fit != BoxFit.cover;
			// maintain minimum pixels on shortest side
			final targetHeight = (targetLongestSide && (attachment.aspectRatio < 1)) || 
													(!targetLongestSide && (attachment.aspectRatio > 1));
			image = ExtendedResizeImage(
				image,
				maxBytes: null,
				width: targetHeight ? null : pixelation,
				height: targetHeight ? pixelation : null,
			);
		}
		else if ((resize || isFallback) && effectiveWidth.isFinite && effectiveHeight.isFinite) {
			filterQuality = FilterQuality.low;
			image = ExtendedResizeImage(
				image,
				maxBytes: 800 << 10,
				width: overrideFullQuality == true ? null : (effectiveWidth * MediaQuery.devicePixelRatioOf(context)).ceil()
			);
		}
		else {
			filterQuality = FilterQuality.low;
		}
		final afterPaint = makeAfterPaint();
		Widget child = ExtendedImage(
			image: image,
			constraints: expand ? null : BoxConstraints(
				maxWidth: effectiveWidth,
				maxHeight: effectiveHeight
			),
			width: effectiveWidth,
			height: shrinkHeight || expand ? null : effectiveHeight,
			color: const Color.fromRGBO(238, 242, 255, 1),
			colorBlendMode: BlendMode.dstOver,
			fit: fit,
			alignment: alignment,
			// A new key is what makes a retry actually load again, including
			// when [suppressImageRebuild] is set
			key: ValueKey((url, retryGeneration)),
			gaplessPlayback: true,
			suppressRebuild: suppressImageRebuild,
			rotate90DegreesClockwise: rotate90DegreesClockwise,
			afterPaintImage: afterPaint == null ? null : (
				key: afterPaint.key,
				fn: (canvas, rect, image, paint) {
					afterPaint.afterPaint(canvas, rect);
				}
			),
			filterQuality: filterQuality,
			loadStateChanged: (loadstate) {
				if (loadstate.extendedImageLoadState == LoadState.loading) {
					return _AttachmentThumbnailPlaceholder(
						effectiveWidth: effectiveWidth,
						effectiveHeight: effectiveHeight,
						attachment: attachment,
						fit: fit,
						afterPaint: makeAfterPaint(),
						child: const CircularProgressIndicator.adaptive()
					);
				}
				else if (
					// Image loading failed
					loadstate.extendedImageLoadState == LoadState.failed ||
					(
						// The real image dimensions were 1x1 (thumbnailer-failed placeholder)
						pixelation != 1 &&
						(loadstate.extendedImageInfo?.image.height ?? 0) == 1) &&
						((loadstate.extendedImageInfo?.image.width ?? 0) == 1)
					) {
					if (loadstate.extendedImageLoadState == LoadState.failed) {
						// Don't break the Widget tree
						Future.microtask(() => onLoadError?.call(loadstate.lastException, loadstate.lastStack));
						// Ask _RetryingPreviewImage to try again, then to use the
						// full-size image if this was only the thumbnail
						onLoadFailed();
					}
					final icon = loadstate.extendedImageLoadState == LoadState.failed && url.isNotEmpty && !site.hasUnreliableThumbnails ? CupertinoIcons.exclamationmark_triangle_fill : (attachment.icon ?? Adaptive.icons.photo);
					return _AttachmentThumbnailPlaceholder(
						child: null,
						icon: icon,
						effectiveWidth: effectiveWidth,
						effectiveHeight: effectiveHeight,
						attachment: attachment,
						afterPaint: makeAfterPaint(alreadyShowingBigIcon: icon),
						fit: fit
					);
				}
				else if (loadstate.extendedImageLoadState == LoadState.completed) {
					attachment.width ??= loadstate.extendedImageInfo?.image.width;
					attachment.height ??= loadstate.extendedImageInfo?.image.height;
				}
				return null;
			}
		);
		if (settings.blurThumbnails && mayObscure) {
			child = ClipRect(
				child: ImageFiltered(
					imageFilter: ImageFilter.blur(
						sigmaX: 7.0,
						sigmaY: 7.0,
						tileMode: TileMode.decal
					),
					child: child
				)
			);
		}
		if (!settings.thumbnailOpacity.isNegative && mayObscure) {
			child = Opacity(
				opacity: settings.thumbnailOpacity,
				child: child
			);
		}
		return child;
	}

	@override
	Widget build(BuildContext context) {
		final settings = context.watch<Settings>();
		double effectiveWidth = width ?? settings.thumbnailSize;
		double effectiveHeight = height ?? settings.thumbnailSize;
		if (shrinkHeight && fit == BoxFit.contain && attachment.width != null && attachment.height != null) {
			if (attachment.aspectRatio > 1) {
				effectiveHeight = effectiveWidth / attachment.aspectRatio;
			}
		}
		if (rotate90DegreesClockwise) {
			final tmp = effectiveWidth;
			effectiveWidth = effectiveHeight;
			effectiveHeight = tmp;
		}
		if (effectiveWidth <= 125 && effectiveHeight <= 125 && !attachment.thumbnailUrl.startsWith(thumbsApiPrefix)) {
			// Don't even try to monitor for HQ caching
			return _build(
				context: context,
				settings: settings,
				effectiveWidth: effectiveWidth,
				effectiveHeight: effectiveHeight,
				forceFullQuality: false
			);
		}
		return StreamBuilder(
			stream: AttachmentCache.stream.where((e) => e.$1.url == attachment.url && e.$2 != this),
			builder: (context, _) => FutureBuilder(
				future: AttachmentCache.optimisticallyFindFile(attachment),
				builder: (context, snapshot) {
					return _build(
						context: context,
						settings: settings,
						effectiveWidth: effectiveWidth,
						effectiveHeight: effectiveHeight,
						forceFullQuality: snapshot.hasData
					);
				}
			)
		);
	}
}

/// Delays used before trying a preview image again after a failed load. A site
/// can publish a file before the thumbnail variant of it.
const _previewLoadRetryDelays = [
	Duration(milliseconds: 500),
	Duration(seconds: 2)
];

typedef _PreviewImageBuilder = Widget Function(BuildContext context, String url, bool isFallback, int retryGeneration, VoidCallback onLoadFailed);

/// Keeps a preview image from staying broken after a single failed load.
///
/// [ExtendedImage] remembers its [LoadState.failed] forever, even though the
/// failure is not cached anywhere, so nothing retries it until it is rebuilt
/// with a different image. This retries a couple of times with a short delay,
/// then swaps in [fallbackUrl] — the attachment's full-size image, which
/// decodes to the same looking preview.
class _RetryingPreviewImage extends StatefulWidget {
	final String url;
	/// Used when [url] keeps failing. If null, the failure is shown as-is.
	final String? fallbackUrl;
	final _PreviewImageBuilder builder;

	const _RetryingPreviewImage({
		required this.url,
		required this.fallbackUrl,
		required this.builder
	});

	@override
	State<_RetryingPreviewImage> createState() => _RetryingPreviewImageState();
}

class _RetryingPreviewImageState extends State<_RetryingPreviewImage> {
	/// Failures so far. Doubles as the generation which [builder] puts in the
	/// image's key, since a new key is what makes [ExtendedImage] load again:
	/// [ExtendedImageState.reLoadImage] does nothing when the widget suppresses
	/// rebuilds of an unchanged image.
	int _failedAttempts = 0;
	bool _usingFallback = false;
	Timer? _retryTimer;

	@override
	void dispose() {
		_retryTimer?.cancel();
		super.dispose();
	}

	@override
	void didUpdateWidget(_RetryingPreviewImage oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.url != widget.url || oldWidget.fallbackUrl != widget.fallbackUrl) {
			// A different image deserves its own retries
			_retryTimer?.cancel();
			_retryTimer = null;
			_failedAttempts = 0;
			_usingFallback = false;
		}
	}

	void _onLoadFailed() {
		if (_retryTimer != null) {
			// Already retrying this failure
			return;
		}
		if (_failedAttempts < _previewLoadRetryDelays.length) {
			final attempt = _failedAttempts;
			_retryTimer = Timer(_previewLoadRetryDelays[attempt], () {
				_retryTimer = null;
				if (!mounted) {
					return;
				}
				setState(() {
					_failedAttempts = attempt + 1;
				});
			});
		}
		else if (!_usingFallback && widget.fallbackUrl != null && widget.fallbackUrl != widget.url) {
			_retryTimer = Timer(Duration.zero, () {
				_retryTimer = null;
				if (!mounted) {
					return;
				}
				setState(() {
					_usingFallback = true;
				});
			});
		}
	}

	@override
	Widget build(BuildContext context) => widget.builder(
		context,
		_usingFallback ? widget.fallbackUrl! : widget.url,
		_usingFallback,
		_failedAttempts,
		_onLoadFailed
	);
}

class _AttachmentThumbnailPlaceholder extends StatelessWidget {
	final Widget? child;
	final IconData? icon;
	final Attachment attachment;
	final double effectiveWidth;
	final double effectiveHeight;
	final BoxFit fit;
	final _KeyedAfterPaint? afterPaint;

	const _AttachmentThumbnailPlaceholder({
		required this.child,
		this.icon,
		required this.attachment,
		required this.effectiveWidth,
		required this.effectiveHeight,
		required this.fit,
		required this.afterPaint
	});

	@override
	Widget build(BuildContext context) {
		final theme = context.watch<SavedTheme>();
		return CustomSingleChildLayout(
			delegate: _AttachmentThumbnailPlaceholderLayoutDelegate(
				attachment: attachment,
				effectiveWidth: effectiveWidth,
				effectiveHeight: effectiveHeight,
				fit: fit
			),
			child: CustomPaint(
				foregroundPainter: _AttachmentThumbnailPlaceholderAfterPaintCustomPainter(afterPaint),
				child: DecoratedBox(
					decoration: BoxDecoration(
						color: theme.barColor
					),
					child: Center(
						child: switch (icon) {
							IconData icon => CustomPaint(
								painter: _AttachmentThumbnailPlaceholderIconCustomPainter(
									icon: icon,
									color: theme.primaryColor
								),
								child: const SizedBox.expand()
							),
							null => child
						}
					)
				)
			)
		);
	}
}

class _AttachmentThumbnailPlaceholderLayoutDelegate extends SingleChildLayoutDelegate {
	final BoxFit fit;
	final double effectiveWidth;
	final double effectiveHeight;
	final Attachment attachment;

	const _AttachmentThumbnailPlaceholderLayoutDelegate({
		required this.fit,
		required this.effectiveWidth,
		required this.effectiveHeight,
		required this.attachment
	});

	Size _getChildSize(BoxConstraints constraints) {
		Size biggest = constraints.biggest;
		if (biggest.isInfinite) {
			biggest = Size(effectiveWidth, effectiveHeight);
		}
		return applyBoxFit(fit, Size(attachment.width?.toDouble() ?? effectiveWidth, attachment.height?.toDouble() ?? effectiveHeight), biggest).destination;
	}

	@override
	Size getSize(BoxConstraints constraints) {
		return _getChildSize(constraints);
	}

	@override
	BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
		return BoxConstraints.tight(_getChildSize(constraints));
	}

	@override
	Offset getPositionForChild(Size size, Size childSize) {
		return Alignment.center.inscribe(childSize, Offset.zero & size).topLeft;
	}

	@override
	bool shouldRelayout(_AttachmentThumbnailPlaceholderLayoutDelegate oldDelegate) {
		return
			oldDelegate.fit != fit ||
			oldDelegate.effectiveWidth != effectiveWidth ||
			oldDelegate.effectiveHeight != effectiveHeight ||
			oldDelegate.attachment != attachment;
	}
}

class _AttachmentThumbnailPlaceholderIconCustomPainter extends CustomPainter {
	final IconData icon;
	final Color color;

	const _AttachmentThumbnailPlaceholderIconCustomPainter({
		required this.icon,
		required this.color
	});

	@override
	void paint(Canvas canvas, Size size) {
		final fontSize = (0.5 * size.shortestSide).clamp(24.0, 100.0);
		TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr);
		textPainter.text = IconSpan(
			icon: icon,
			size: fontSize,
			color: color
		);
		textPainter.layout();
		textPainter.paint(canvas, Alignment.center.inscribe(textPainter.size, Offset.zero & size).topLeft);
	}

	@override
	bool shouldRepaint(_AttachmentThumbnailPlaceholderIconCustomPainter oldDelegate) {
		return oldDelegate.icon != icon;
	}
}

class _AttachmentThumbnailPlaceholderAfterPaintCustomPainter extends CustomPainter {
	final _KeyedAfterPaint? afterPaint;

	const _AttachmentThumbnailPlaceholderAfterPaintCustomPainter(this.afterPaint);

	@override
	bool shouldRepaint(_AttachmentThumbnailPlaceholderAfterPaintCustomPainter oldDelegate) {
		return oldDelegate.afterPaint?.key != afterPaint?.key;
	}
	
	@override
	void paint(Canvas canvas, Size size) {
		afterPaint?.afterPaint.call(canvas, Offset.zero & size);
	}
}
