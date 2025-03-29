//
//  KeyboardManager.swift
//  InputBarAccessoryView
//
//  Copyright © 2017-2020 Nathan Tannar.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Created by Nathan Tannar on 8/18/17.
//

import UIKit
import Combine

/// An object that observes keyboard notifications such that event callbacks can be set for each notification
@available(iOSApplicationExtension, unavailable)
open class KeyboardManager: NSObject, UIGestureRecognizerDelegate {
    
    /// A callback that passes a `KeyboardNotification` as an input
    public typealias EventCallback = (KeyboardNotification)->Void
    
    // MARK: - Properties [Public]
    
    /// A weak reference to a view bounded to the top of the keyboard to act as an `InputAccessoryView`
    /// but kept within the bounds of the `UIViewController`s view
    open weak var inputAccessoryView: UIView?
        
    /// A flag that indicates if a portion of the keyboard is visible on the screen
    /// - Deprecated: Use `isKeyboardVisible` instead.
    @available(*, deprecated, message: "Use `isKeyboardVisible` instead.")
    private(set) public var isKeyboardHidden: Bool = true {
        didSet {
            isKeyboardVisible = !isKeyboardHidden
        }
    }
    
    /// A flag that indicates if a portion of the keyboard is visible on the screen (true from `keyboardWillShow` to `keyboardDidHide`).
    private(set) public var isKeyboardVisible: Bool = false
    
    /// A flag that indicates if the keyboard has been fully shown (true from `keyboardDidShow` to `keyboardWillHide`).
    private(set) public var isKeyboardFullyVisible: Bool = false
    
    /// A flag that indicates if the additional bottom space should be applied to
    /// the interactive dismissal of the keyboard
    public var shouldApplyAdditionBottomSpaceToInteractiveDismissal: Bool = false
    
    /// Closure for providing an additional bottom constraint constant for `InputAccessoryView`
    public var additionalInputViewBottomConstraintConstant: () -> CGFloat = { 0 }
    
    // MARK: - Properties [Private]
    
    /// The additional bottom space specified for laying out the input accessory view
    /// when binding to it
    private var additionalBottomSpace: (() -> CGFloat)?
    
    /// The `NSLayoutConstraintSet` that holds the `inputAccessoryView` to the bottom if its superview
    private var constraints: NSLayoutConstraintSet?
    
    /// A weak reference to a `UIScrollView` that has been attached for interactive keyboard dismissal
    private weak var scrollView: UIScrollView?
    
    /// The `EventCallback` actions for each `KeyboardEvent`. Default value is EMPTY
    private var callbacks: [KeyboardEvent: EventCallback] = [:]
    
    /// A cached notification used as a starting point when a user dragging the `scrollView` down
    /// to interactively dismiss the keyboard
    private var cachedNotification: KeyboardNotification?
    
    /// Used to fix a glitch that would otherwise occur when using pagesheets on iPad in iOS 14
    private var justDidWillHide = false
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    /// Creates a `KeyboardManager` object an binds the view as fake `InputAccessoryView`
    ///
    /// - Parameter inputAccessoryView: The view to bind to the top of the keyboard but within its superview
    public convenience init(inputAccessoryView: UIView) {
        self.init()
        self.bind(inputAccessoryView: inputAccessoryView)
    }
    
    /// Creates a `KeyboardManager` object that observes the state of the keyboard
    public override init() {
        super.init()
        addObservers()
    }
    
    public required init?(coder: NSCoder) { nil }
    
    // MARK: - De-Initialization
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Keyboard Observer
    
    /// Add an observer for each keyboard notification
    private func addObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillShow(notification:)),
                                               name: UIResponder.keyboardWillShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidShow(notification:)),
                                               name: UIResponder.keyboardDidShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(notification:)),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidHide(notification:)),
                                               name: UIResponder.keyboardDidHideNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillChangeFrame(notification:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardDidChangeFrame(notification:)),
                                               name: UIResponder.keyboardDidChangeFrameNotification,
                                               object: nil)
    }
    
    // MARK: - Mutate Callback Dictionary
    
    /// Sets the `EventCallback` for a `KeyboardEvent`
    ///
    /// - Parameters:
    ///   - event: KeyboardEvent
    ///   - callback: EventCallback
    /// - Returns: Self
    @discardableResult
    open func on(event: KeyboardEvent, do callback: EventCallback?) -> Self {
        callbacks[event] = callback
        return self
    }
    
    /// When e.g. using pagesheets on iPad the inputAccessoryView is not stuck to the bottom of the screen.
    /// This value represents the size of the gap between the bottom of the screen and the bottom of the inputAccessoryView.
    private var bottomGap: CGFloat {
        if let inputAccessoryView = inputAccessoryView, let window = inputAccessoryView.window, let superview = inputAccessoryView.superview {
            return window.frame.height - window.convert(superview.frame, to: window).maxY
        }
        return 0
    }
    
    /// Constrains the `inputAccessoryView` to the bottom of its superview and sets the
    /// `.willChangeFrame` and `.willHide` event callbacks such that it mimics an `InputAccessoryView`
    /// that is bound to the top of the keyboard
    ///
    /// - Parameter inputAccessoryView: The view to bind to the top of the keyboard but within its superview
    /// - Returns: Self
    @discardableResult
    open func bind(inputAccessoryView: UIView, withAdditionalBottomSpace additionalBottomSpace: (() -> CGFloat)? = .none) -> Self {
        
        guard let superview = inputAccessoryView.superview else {
            fatalError("`inputAccessoryView` must have a superview")
        }
        self.inputAccessoryView = inputAccessoryView
        self.additionalBottomSpace = additionalBottomSpace
        inputAccessoryView.translatesAutoresizingMaskIntoConstraints = false
        constraints?.bottom?.isActive = false
        constraints = NSLayoutConstraintSet(
            bottom: inputAccessoryView.bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: additionalInputViewBottomConstraintConstant()),
            left: inputAccessoryView.leftAnchor.constraint(equalTo: superview.leftAnchor),
            right: inputAccessoryView.rightAnchor.constraint(equalTo: superview.rightAnchor)
        ).activate()
        
        callbacks[.willShow] = { [weak self] (notification) in
            guard
                self?.isKeyboardVisible == true,
                self?.constraints?.bottom?.constant == self?.additionalInputViewBottomConstraintConstant(),
                notification.isForCurrentApp
            else { return }
            
            let keyboardHeight = notification.endFrame.height
            let animateAlongside = {
                self?.animateAlongside(notification) {
                    self?.constraints?.bottom?.constant = min(0, -keyboardHeight + (self?.bottomGap ?? 0)) - (additionalBottomSpace?() ?? 0)
                    self?.inputAccessoryView?.superview?.layoutIfNeeded()
                }
            }
            animateAlongside()
            
            // Trigger a new animation if gap changed, this typically happens when using pagesheet on portrait iPad
            let initialBottomGap = self?.bottomGap ?? 0
            DispatchQueue.main.async {
                let newBottomGap = self?.bottomGap ?? 0
                if newBottomGap != 0 && newBottomGap != initialBottomGap {
                    animateAlongside()
                }
            }
        }
        callbacks[.willChangeFrame] = { [weak self] (notification) in
            let keyboardHeight = notification.endFrame.height
            guard
                self?.isKeyboardVisible == true,
                notification.isForCurrentApp
            else {
                return
            }
            let animateAlongside = {
                self?.animateAlongside(notification) {
                    self?.constraints?.bottom?.constant = min(0, -keyboardHeight + (self?.bottomGap ?? 0)) - (additionalBottomSpace?() ?? 0)
                    self?.inputAccessoryView?.superview?.layoutIfNeeded()
                }
            }
            animateAlongside()
            
            // Trigger a new animation if gap changed, this typically happens when using pagesheet on portrait iPad
            let initialBottomGap = self?.bottomGap ?? 0
            DispatchQueue.main.async {
                let newBottomGap = self?.bottomGap ?? 0
                if newBottomGap != 0 && newBottomGap != initialBottomGap && !(self?.justDidWillHide ?? false) {
                    animateAlongside()
                }
            }
        }
        callbacks[.willHide] = { [weak self] (notification) in
            guard notification.isForCurrentApp else { return }
            self?.justDidWillHide = true
            self?.animateAlongside(notification) { [weak self] in
                self?.constraints?.bottom?.constant = self?.additionalInputViewBottomConstraintConstant() ?? 0
                self?.inputAccessoryView?.superview?.layoutIfNeeded()
            }
            DispatchQueue.main.async {
                self?.justDidWillHide = false
            }
        }
        return self
    }
    
    /// Binds to a UIScrollView and synchronizes keyboard dismissal behavior
    /// - Note: Automatically manages pan gesture for `.interactiveWithAccessory` mode
    /// - Parameter scrollView: The scroll view to bind
    /// - Returns: Self
    @discardableResult
    open func bind(to scrollView: UIScrollView) -> Self {
        self.scrollView = scrollView
        scrollView.publisher(for: \.keyboardDismissMode)
            .sink { [weak self] mode in
                guard let self = self else { return }
                if scrollView.keyboardDismissMode == .interactiveWithAccessory {
                    scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePanGestureRecognizer))
                } else {
                    scrollView.panGestureRecognizer.removeTarget(self, action:  #selector(handlePanGestureRecognizer))
                }
            }
            .store(in: &cancellables) // 统一存储，避免内存泄漏
        return self
    }
    
    @discardableResult
    open func unbind() -> Self {
        // Clear additional bottom space
        self.additionalBottomSpace = nil
        self.inputAccessoryView = nil
        self.scrollView = nil
        
        // Remove keyboard callbacks
        self.callbacks[.willShow] = nil
        self.callbacks[.didShow] = nil
        self.callbacks[.willChangeFrame] = nil
        self.callbacks[.willHide] = nil
        self.callbacks[.didHide] = nil
        
        // Unbind scrollView-related configurations
        if let scrollView = self.scrollView {
            // Remove target from the pan gesture recognizer
            scrollView.panGestureRecognizer.removeTarget(self, action: #selector(self.handlePanGestureRecognizer))
            
            // Cancel all keyboard dismissal mode subscriptions
            cancellables.forEach { $0.cancel() }
            cancellables.removeAll()
        }
        
        return self
    }
    
    // MARK: - Keyboard Notifications
    
    /// An observer method called last in the lifecycle of a keyboard becoming visible
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardDidShow(notification: NSNotification) {
        isKeyboardFullyVisible = true
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        callbacks[.didShow]?(keyboardNotification)
    }
    
    /// An observer method called last in the lifecycle of a keyboard becoming hidden
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardDidHide(notification: NSNotification) {
        isKeyboardVisible = false
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        callbacks[.didHide]?(keyboardNotification)
        cachedNotification = nil
    }
    
    /// An observer method called third in the lifecycle of a keyboard becoming visible/hidden
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardDidChangeFrame(notification: NSNotification) {
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        callbacks[.didChangeFrame]?(keyboardNotification)
        cachedNotification = keyboardNotification
    }
    
    /// An observer method called first in the lifecycle of a keyboard becoming visible/hidden
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardWillChangeFrame(notification: NSNotification) {
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        callbacks[.willChangeFrame]?(keyboardNotification)
        cachedNotification = keyboardNotification
    }
    
    /// An observer method called second in the lifecycle of a keyboard becoming visible
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardWillShow(notification: NSNotification) {
        isKeyboardVisible = true
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        callbacks[.willShow]?(keyboardNotification)
    }
    
    /// An observer method called second in the lifecycle of a keyboard becoming hidden
    ///
    /// - Parameter notification: NSNotification
    @objc
    open func keyboardWillHide(notification: NSNotification) {
        guard let keyboardNotification = KeyboardNotification(from: notification) else { return }
        isKeyboardFullyVisible = false
        callbacks[.willHide]?(keyboardNotification)
        cachedNotification = nil
    }
    
    // MARK: - Helper Methods
    
    private func animateAlongside(_ notification: KeyboardNotification, animations: @escaping ()->Void) {
        UIView.animate(withDuration: notification.timeInterval, delay: 0, options: [notification.animationOptions, .allowAnimatedContent, .beginFromCurrentState], animations: animations, completion: nil)
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    /// Starts with the cached `KeyboardNotification` and calculates a new `endFrame` based
    /// on the `UIPanGestureRecognizer` then calls the `.willChangeFrame` `EventCallback` action
    ///
    /// - Parameter recognizer: UIPanGestureRecognizer
    @objc
    open func handlePanGestureRecognizer(recognizer: UIPanGestureRecognizer) {
        guard
            var keyboardNotification = cachedNotification,
            case .changed = recognizer.state,
            let view = recognizer.view,
            let window = UIApplication.shared.windows.first
        else { return }
        
        guard
            // if there's no difference in frames for the `cachedNotification`, no adjustment is necessary.
            // This is true when the keyboard is completely dismissed, or our pan doesn't intersect below the keyboard
            keyboardNotification.startFrame != keyboardNotification.endFrame,
            // when the width of the keyboard from endFrame is smaller than the width of scrollView manager is tracking
            // with panGesture, we can assume the keyboard is floatig ahd updating inputAccessoryView is not necessary
                keyboardNotification.endFrame.width >= view.frame.width
        else {
            return
        }
        
        let location = recognizer.location(in: view)
        let absoluteLocation = view.convert(location, to: window)
        var frame = keyboardNotification.endFrame
        frame.origin.y = max(absoluteLocation.y, window.bounds.height - frame.height)
        frame.size.height = window.bounds.height - frame.origin.y
        keyboardNotification.endFrame = frame
        
        var yCoordinateDirectlyAboveKeyboard = -frame.height + bottomGap
        if shouldApplyAdditionBottomSpaceToInteractiveDismissal, let additionalBottomSpace = additionalBottomSpace {
            yCoordinateDirectlyAboveKeyboard -= additionalBottomSpace()
        }
        
        /// If a tab bar is shown, letting this number becoming > 0 makes it so the accessoryview disappears below the tab bar. setting the max value to 0 prevents that
        let aboveKeyboardAndAboveTabBar = min(additionalInputViewBottomConstraintConstant(), yCoordinateDirectlyAboveKeyboard)
        self.constraints?.bottom?.constant = aboveKeyboardAndAboveTabBar
        self.inputAccessoryView?.superview?.layoutIfNeeded()
    }
}
