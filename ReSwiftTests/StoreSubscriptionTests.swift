//
//  StoreSubscriptionTests.swift
//  ReSwift
//
//  Created by Benjamin Encz on 11/27/15.
//  Copyright © 2015 ReSwift Community. All rights reserved.
//

import XCTest
/**
 @testable import for testing of `Store.subscriptions`
 */
@testable import ReSwift

class StoreSubscriptionTests: XCTestCase {

    typealias TestSubscriber = TestStoreSubscriber<TestAppState>

    var store: Store<TestAppState>!
    var reducer: TestReducer!

    override func setUp() {
        super.setUp()
        reducer = TestReducer()
        store = Store(reducer: reducer.handleAction, state: TestAppState())
    }

    /**
     It does not strongly capture an observer
     */
    func testDoesNotCaptureStrongly() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        var subscriber: TestSubscriber? = TestSubscriber()

        store.subscribe(subscriber!)
        XCTAssertEqual(store.subscriptions.compactMap({ $0.subscriber }).count, 1)
        // Ensure `subscriber` is accessed at least once to prevent it being optimised
        // away when tests are built using 'release' scheme. #459 refers.
        XCTAssertNotNil(subscriber)

        subscriber = nil
        XCTAssertEqual(store.subscriptions.compactMap({ $0.subscriber }).count, 0)
    }

    /**
     it removes deferenced subscribers before notifying state changes
     */
    func testRemoveSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        var subscriber1: TestSubscriber? = TestSubscriber()
        var subscriber2: TestSubscriber? = TestSubscriber()

        store.subscribe(subscriber1!)
        store.subscribe(subscriber2!)
        store.dispatch(SetValueAction(3))
        XCTAssertEqual(store.subscriptions.count, 2)
        XCTAssertEqual(subscriber1?.receivedStates.last?.testValue, 3)
        XCTAssertEqual(subscriber2?.receivedStates.last?.testValue, 3)

        subscriber1 = nil
        store.dispatch(SetValueAction(5))
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(subscriber2?.receivedStates.last?.testValue, 5)

        subscriber2 = nil
        store.dispatch(SetValueAction(8))
        XCTAssertEqual(store.subscriptions.count, 0)
    }

    /**
     it keeps subscriptions consistent when another thread subscribes and unsubscribes
     while this thread dispatches
     */
    func testSubscribeAndUnsubscribeOnAnotherThreadWhileDispatching() {
        let store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscribers = (0..<20).map { _ in TestSubscriber() }
        subscribers.forEach { store.subscribe($0) }

        let churn = DispatchGroup()
        churn.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let subscriber = BlockSubscriber<TestAppState> { _ in }
                store.subscribe(subscriber)
                store.unsubscribe(subscriber)
                // Released straight away, leaving a stale box for the next dispatch to remove.
                store.subscribe(BlockSubscriber<TestAppState> { _ in })
            }
            churn.leave()
        }

        var dispatches = 0
        while churn.wait(timeout: .now()) == .timedOut {
            store.dispatch(SetValueAction(dispatches))
            dispatches += 1
        }
        store.dispatch(SetValueAction(dispatches))

        XCTAssertEqual(store.subscriptions.count, subscribers.count)
        XCTAssertEqual(subscribers.last?.receivedStates.last?.testValue, dispatches)
    }

    /**
     it lets the teardown of an unsubscribed subscription unsubscribe another subscriber
     */
    func testUnsubscribeWhoseTeardownUnsubscribes() {
        let store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()
        let other = TestSubscriber()
        store.subscribe(other)
        subscribe(subscriber, to: store, keepingAlive: DeinitObserver { store.unsubscribe(other) })

        // Removing the box releases its selector, and with it the observer that unsubscribes `other`.
        store.unsubscribe(subscriber)

        XCTAssertEqual(store.subscriptions.count, 0)
    }

    /**
     it lets the teardown of a replaced subscription unsubscribe another subscriber
     */
    func testResubscribeWhoseTeardownUnsubscribes() {
        let store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()
        let other = TestSubscriber()
        store.subscribe(other)
        subscribe(subscriber, to: store, keepingAlive: DeinitObserver { store.unsubscribe(other) })

        // Subscribing again replaces the box, which releases the observer that unsubscribes `other`.
        store.subscribe(subscriber)

        XCTAssertEqual(store.subscriptions.count, 1)
    }

    private func subscribe(_ subscriber: TestSubscriber, to store: Store<TestAppState>,
                           keepingAlive observer: DeinitObserver) {
        store.subscribe(subscriber) { subscription in
            subscription.select { state -> TestAppState in
                withExtendedLifetime(observer) {}
                return state
            }
        }
    }

    /**
     it replaces the subscription of an existing subscriber with the new one.
     */
    func testDuplicateSubscription() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        // Initial subscription.
        store.subscribe(subscriber)
        // Subsequent subscription that skips repeated updates.
        store.subscribe(subscriber) { $0.skipRepeats { $0.testValue == $1.testValue } }

        // One initial state update for every subscription.
        XCTAssertEqual(subscriber.receivedStates.count, 2)

        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))
        store.dispatch(SetValueAction(3))

        // Only a single further state update, since latest subscription skips repeated values.
        XCTAssertEqual(subscriber.receivedStates.count, 3)
    }

    /**
     it dispatches initial value upon subscription
     */
    func testDispatchInitialValue() {
        store = Store(reducer: reducer.handleAction, state: TestAppState(testValue: 7))
        let subscriber = TestSubscriber()

        store.subscribe(subscriber)

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [7])
    }

    /**
     it dispatches initial value upon subscription and subsequent state changes
     */
    func testDispatchStateChanges() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(9))

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [nil, 9])
    }

    /**
     it dispatches initial value upon subscription and subsequent state changes
     */
    func testDispatchInitialStateAfterStateChange() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        // Change state first ...
        store.dispatch(SetValueAction(13))
        // ... and then subscribe to receive the current state.
        store.subscribe(subscriber)

        XCTAssertEqual(subscriber.receivedStates.map(\.testValue), [13])
    }

    /**
     it allows dispatching from within an observer
     */
    func testAllowDispatchWithinObserver() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = DispatchingSubscriber(store: store)

        store.subscribe(subscriber)
        store.dispatch(SetValueAction(2))

        XCTAssertEqual(store.state.testValue, 5)
    }

    /**
     it does not dispatch value after subscriber unsubscribes
     */
    func testDontDispatchToUnsubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.dispatch(SetValueAction(5))
        store.subscribe(subscriber)
        store.dispatch(SetValueAction(10))

        store.unsubscribe(subscriber)
        // Following value is missed due to not being subscribed:
        store.dispatch(SetValueAction(15))
        store.dispatch(SetValueAction(25))

        store.subscribe(subscriber)

        store.dispatch(SetValueAction(20))

        XCTAssertEqual(subscriber.receivedStates.count, 4)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 4].testValue, 5)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 3].testValue, 10)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 2].testValue, 25)
        XCTAssertEqual(subscriber.receivedStates[subscriber.receivedStates.count - 1].testValue, 20)
    }

    /**
     it ignores identical subscribers
     */
    func testIgnoreIdenticalSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber)
        store.subscribe(subscriber)

        XCTAssertEqual(store.subscriptions.count, 1)
    }

    /**
     it ignores identical subscribers that provide substate selectors
     */
    func testIgnoreIdenticalSubstateSubscribers() {
        store = Store(reducer: reducer.handleAction, state: TestAppState())
        let subscriber = TestSubscriber()

        store.subscribe(subscriber) { $0 }
        store.subscribe(subscriber) { $0 }

        XCTAssertEqual(store.subscriptions.count, 1)
    }

    func testNewStateModifyingSubscriptionsDoesNotDiscardNewSubscription() {
        // This was built as a failing test due to a bug introduced by #325
        // The bug occured by adding a subscriber during `newState`
        // The bug was caused by creating a copy of `subscriptions` before calling
        // `newState`, and then assigning that copy back to `subscriptions`, losing
        // the mutation that occured during `newState`

        store = Store(reducer: reducer.handleAction, state: TestAppState())

        let subscriber2 = BlockSubscriber<TestAppState> { _ in
            self.store.dispatch(SetValueAction(2))
        }

        let subscriber1 = BlockSubscriber<TestAppState> { [unowned self] state in
            if state.testValue == 1 {
                self.store.subscribe(subscriber2) {
                    $0.skip(when: { _, _ in return true })
                }
            }
        }

        store.subscribe(subscriber1) {
            $0.only(when: { _, new in new.testValue.map { $0 == 1 } ?? false })
        }

        store.dispatch(SetValueAction(1))

        XCTAssertTrue(store.subscriptions.contains(where: {
            guard let subscriber = $0.subscriber else {
                XCTFail("expecting non-nil subscriber")
                return false
            }
            return subscriber === subscriber1
        }))
        XCTAssertTrue(store.subscriptions.contains(where: {
            guard let subscriber = $0.subscriber else {
                XCTFail("expecting non-nil subscriber")
                return false
            }
            return subscriber === subscriber2
        }))

        // Have a subscriber (#1)
        // #1 adds sub #2 in newState
        // #1 dispatches in newState
        // Test that store.subscribers == [#1, #2] // this should fail
    }
}

// MARK: Retain Cycle Detection

private struct TracerAction: Action { }

private class TestSubscriptionBox<S>: SubscriptionBox<S> {
    override init<T>(
        originalSubscription: Subscription<S>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber
        ) {
        super.init(originalSubscription: originalSubscription,
                   transformedSubscription: transformedSubscription,
                   subscriber: subscriber)
    }

    var didDeinit: (() -> Void)?
    deinit {
        didDeinit?()
    }
}

private class TestStore<State>: Store<State> {
    override func subscriptionBox<T>(
        originalSubscription: Subscription<State>,
        transformedSubscription: Subscription<T>?,
        subscriber: AnyStoreSubscriber) -> SubscriptionBox<State> {
        return TestSubscriptionBox(
            originalSubscription: originalSubscription,
            transformedSubscription: transformedSubscription,
            subscriber: subscriber
        )
    }
}

extension StoreSubscriptionTests {

    func testRetainCycle_OriginalSubscription() {

        var didDeinit = false

        autoreleasepool {

            store = TestStore(reducer: reducer.handleAction, state: TestAppState())
            let subscriber: TestSubscriber = TestSubscriber()

            // Preconditions
            XCTAssertEqual(subscriber.receivedStates.count, 0)
            XCTAssertEqual(store.subscriptions.count, 0)

            autoreleasepool {

                store.subscribe(subscriber)
                XCTAssertEqual(subscriber.receivedStates.count, 1)
                let subscriptionBox = store.subscriptions.first! as! TestSubscriptionBox<TestAppState>
                subscriptionBox.didDeinit = { didDeinit = true }

                store.dispatch(TracerAction())
                XCTAssertEqual(subscriber.receivedStates.count, 2)
                store.unsubscribe(subscriber)
            }

            XCTAssertEqual(store.subscriptions.count, 0)
            store.dispatch(TracerAction())
            XCTAssertEqual(subscriber.receivedStates.count, 2)

            store = nil
        }

        XCTAssertTrue(didDeinit)
    }

    func testRetainCycle_TransformedSubscription() {

        var didDeinit = false

        autoreleasepool {

            store = TestStore(reducer: reducer.handleAction, state: TestAppState(), automaticallySkipsRepeats: false)
            let subscriber = TestStoreSubscriber<Int?>()

            // Preconditions
            XCTAssertEqual(subscriber.receivedStates.count, 0)
            XCTAssertEqual(store.subscriptions.count, 0)

            autoreleasepool {

                store.subscribe(subscriber, transform: {
                    $0.select { $0.testValue }
                })
                XCTAssertEqual(subscriber.receivedStates.count, 1)
                let subscriptionBox = store.subscriptions.first! as! TestSubscriptionBox<TestAppState>
                subscriptionBox.didDeinit = { didDeinit = true }

                store.dispatch(TracerAction())
                XCTAssertEqual(subscriber.receivedStates.count, 2)
                store.unsubscribe(subscriber)
            }

            XCTAssertEqual(store.subscriptions.count, 0)
            store.dispatch(TracerAction())
            XCTAssertEqual(subscriber.receivedStates.count, 2)

            store = nil
        }

        XCTAssertTrue(didDeinit)
    }
}
