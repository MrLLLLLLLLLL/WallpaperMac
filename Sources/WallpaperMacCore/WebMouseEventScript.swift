import Foundation

public enum WebMouseEventPhase: String, Sendable {
    case mouseDown = "mousedown"
    case mouseUp = "mouseup"
}

/// Builds the DOM event bridge used for interactive web wallpapers.
public enum WebMouseEventScript {
    public static func source(
        x: Double,
        y: Double,
        phase: WebMouseEventPhase
    ) -> String {
        let activation = phase == .mouseUp
            ? """
            const down = window.__wallpaperMacMouseDown;
            window.__wallpaperMacMouseDown = null;
            const event = element.dispatchEvent(new MouseEvent('\(phase.rawValue)', common));
            if (down && down.target && Math.hypot(x - down.x, y - down.y) <= 6 && !event.defaultPrevented) {
              let target = null;
              if (down.target === element) {
                target = element;
              } else if (down.target.contains(element)) {
                target = down.target;
              } else if (element.contains(down.target)) {
                target = element;
              }
              if (target) {
                if (typeof target.click === 'function') {
                  target.click();
                } else {
                  target.dispatchEvent(new MouseEvent('click', common));
                }
              }
            }
            """
            : """
            window.__wallpaperMacMouseDown = {
              x, y, target: element,
              accepted: element.dispatchEvent(new MouseEvent('\(phase.rawValue)', common))
            };
            """
        return """
        (() => {
          const x = \(x);
          const y = \(y);
          const element = document.elementFromPoint(x, y) || document.body;
          if (!element) return;
          const common = { bubbles: true, cancelable: true, clientX: x, clientY: y };
          \(activation)
        })();
        """
    }

    public static func evaluateMouseUp(x: Double, y: Double) -> String {
        """
        (() => {
          const x = \(x);
          const y = \(y);
          const element = document.elementFromPoint(x, y) || document.body;
          const down = window.__wallpaperMacMouseDown;
          window.__wallpaperMacMouseDown = null;
          window.__wallpaperMacActivationTarget = null;
          if (!element || !down || !down.target || down.accepted === false) {
            return { activate: false, url: '' };
          }
          const accepted = element.dispatchEvent(new MouseEvent('mouseup', {
            bubbles: true, cancelable: true, clientX: x, clientY: y
          }));
          if (!accepted || Math.hypot(x - down.x, y - down.y) > 6) {
            return { activate: false, url: '' };
          }
          let target = null;
          if (down.target === element) {
            target = element;
          } else if (down.target.contains(element)) {
            target = down.target;
          } else if (element.contains(down.target)) {
            target = element;
          }
          if (!target || !target.isConnected) return { activate: false, url: '' };
          window.__wallpaperMacActivationTarget = target;
          window.__wallpaperMacActivationPoint = { x, y };
          const anchor = target.closest ? target.closest('a[href]') : null;
          return { activate: true, url: anchor ? anchor.href : '' };
        })();
        """
    }

    public static func activateMouseUp() -> String {
        """
        (() => {
          const target = window.__wallpaperMacActivationTarget;
          const point = window.__wallpaperMacActivationPoint;
          window.__wallpaperMacActivationTarget = null;
          window.__wallpaperMacActivationPoint = null;
          if (!target || !target.isConnected) return;
          if (typeof target.click === 'function') {
            target.click();
          } else {
            target.dispatchEvent(new MouseEvent('click', {
              bubbles: true,
              cancelable: true,
              clientX: point ? point.x : 0,
              clientY: point ? point.y : 0
            }));
          }
        })();
        """
    }

    public static func clearMouseState() -> String {
        "window.__wallpaperMacMouseDown = null; window.__wallpaperMacActivationTarget = null; window.__wallpaperMacActivationPoint = null;"
    }

    public static func linkTarget(x: Double, y: Double) -> String {
        """
        (() => {
          const element = document.elementFromPoint(\(x), \(y));
          const anchor = element && element.closest ? element.closest('a[href]') : null;
          return anchor ? anchor.href : '';
        })();
        """
    }
}
