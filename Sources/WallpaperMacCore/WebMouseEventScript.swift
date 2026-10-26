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
            if (typeof element.click === 'function') {
              element.click();
            } else {
              element.dispatchEvent(new MouseEvent('click', common));
            }
            """
            : ""
        return """
        (() => {
          const x = \(x);
          const y = \(y);
          const element = document.elementFromPoint(x, y) || document.body;
          if (!element) return;
          const common = { bubbles: true, cancelable: true, clientX: x, clientY: y };
          element.dispatchEvent(new MouseEvent('\(phase.rawValue)', common));
          \(activation)
        })();
        """
    }
}
