---
title: "My strategy for Strategy"
date: 2025-11-20
tags: [patterns, strategy, refactoring, react]
category: tech
draft: true
---

Previously I already touched on the topic of design patterns. Today I want to continue this topic. Once more during my everyday work, I encountered a situation that perfectly illustrates the usage of one, and I think it's worth sharing.

Classic design patterns can feel awkward when transferred directly into modern React. Many of them were designed for stateful class hierarchies, and mapping them one-to-one to hooks and functional components often produces more ceremony than value. But some patterns remain genuinely useful — especially when adapted to fit the functional style rather than forced into their original shape. The Strategy pattern is one of them.

---

## The Problem: Push Notification Fallback

In our app, push notifications are critical for keeping users informed about important events in real time. But what happens when push notifications are disabled? We decided to implement a fallback: when push is off, establish a WebSocket connection through AWS Amplify Events API to receive events through an alternative channel.

The first implementation was a single custom hook that handled everything:

```ts
export const useRealtimeConnection = () => {
  const token = useAuthToken();
  const user = useCurrentUser();
  const { isInternet, isPushEnabled, isInForeground } = useConnectionState();

  const subRef = useRef(null);

  useEffect(() => {
    if (isPushEnabled || !user.id || !isInForeground || !isInternet || !token)
      return;

    configureAmplify();
    let channel;

    const connectAndSubscribe = async () => {
      try {
        channel = await events.connect(`/user/${user.id}/notifications`, {
          authToken: token,
        });
        subRef.current = channel.subscribe({
          next: (data) => onDashboardEvent(data.event),
          error: (err) => console.error("[Realtime] Error:", err),
        });
      } catch (error) {
        console.error("[Realtime] Connection failed");
      }
    };

    connectAndSubscribe();

    return () => {
      subRef.current?.unsubscribe();
      subRef.current = null;
      channel?.close();
    };
  }, [isPushEnabled, token, user, isInForeground, isInternet]);
};
```

This worked perfectly. We were happy and moved on.

---

## The Plot Twist: Registration Needs It Too

A few weeks later, a new requirement arrived: the registration flow also needed real-time event handling. Users go through identity verification, document uploads, and compliance checks — all of which can trigger events that need to be communicated back immediately.

But the registration scope had meaningfully different requirements:

- **Different endpoint** — registration events come from a separate service
- **Different events** — verification status and compliance checks, not account activity
- **Different handlers** — registration-specific logic for processing events
- **Different auth state** — registration users hold a temporary session, not a full account
- **Different user identification** — session ID instead of user ID

My first instinct was to create `useRegistrationRealtimeConnection`, copy the logic, and adjust it. But as soon as I started, alarm bells went off. The details differ, but the structure is identical:

1. Check if connection is needed
2. Establish connection with specific configuration
3. Subscribe to specific events
4. Handle cleanup

That's a textbook duplication risk. That was the moment I reached for the Strategy pattern.

---

## Pattern Recognition: Enter the Strategy

> **Strategy Pattern**: Define a family of algorithms, encapsulate each one, and make them interchangeable. Strategy lets the algorithm vary independently from clients that use it.

Think of navigation apps — fastest route, shortest route, avoid highways. The interface stays the same, but the routing algorithm changes based on your chosen strategy.

In our case, this looked like a good fit for a Strategy-style refactor. The lifecycle algorithm — connect, subscribe, clean up — stays fixed in the hook. What varies is the **connection policy**: when to connect, which endpoint to use, how to identify the user. Extracting that variation into strategy objects would let the hook remain stable while each scope provides its own rules.

I'll come back to whether this is _really_ Strategy in a moment. First, the implementation.

---

## The Implementation: Step by Step

### 1. Folder Structure

```
libs/
  realtime/
    strategies/
      types.ts
      dashboard.ts
      registration.ts
      selectStrategy.ts
      index.ts
    useConnectionState.ts
    useRealtimeConnection.ts
```

### 2. Defining the Strategy Type

```ts
// libs/realtime/strategies/types.ts
export type ConnectionParams = {
  token: string | null;
  user: AppUser | AuthenticatedUser;
  isPushEnabled: boolean;
  isInForeground: boolean;
  isInternet: boolean;
};

export type RealtimeStrategy = {
  scope: "dashboard" | "registration";
  shouldConnect: (params: ConnectionParams) => boolean;
  getEndpoint: (user: AppUser | AuthenticatedUser) => string;
  getIdentifier: (user: AppUser | AuthenticatedUser) => string | number;
};
```

Each strategy is a plain object — no hooks, no side effects, just functions that receive data and return values. `shouldConnect` encodes the policy: given a snapshot of the current environment, should we connect? `scope` is the discriminator that lets the hook route events to the right handler.

### 3. Creating the Concrete Strategies

```ts
// libs/realtime/strategies/dashboard.ts
export const dashboardStrategy: RealtimeStrategy = {
  scope: "dashboard",
  shouldConnect: ({ token, user, isPushEnabled, isInForeground, isInternet }) =>
    isAuthenticated(user) &&
    token != null &&
    !isPushEnabled &&
    isInForeground &&
    isInternet,
  getEndpoint: (user) => {
    if (!isAuthenticated(user)) throw new Error("User not authenticated");
    return `/user/${user.id}/notifications`;
  },
  getIdentifier: (user) => {
    if (!isAuthenticated(user)) throw new Error("User not authenticated");
    return user.id;
  },
};
```

```ts
// libs/realtime/strategies/registration.ts
export const registrationStrategy: RealtimeStrategy = {
  scope: "registration",
  shouldConnect: ({ token, user, isPushEnabled, isInForeground, isInternet }) =>
    !isAuthenticated(user) &&
    token != null &&
    user.sessionId != null &&
    !isPushEnabled &&
    isInForeground &&
    isInternet,
  getEndpoint: (user) => {
    if (!user.sessionId) throw new Error("Session not available");
    return `/registration/${user.sessionId}/notifications`;
  },
  getIdentifier: (user) => user.sessionId ?? "unknown",
};
```

The `isAuthenticated` type guard makes the two strategies mutually exclusive: the dashboard strategy only activates for a fully signed-in user, the registration strategy for an unauthenticated session. Neither touches React — they're pure objects you could test with a single function call.

### 4. Strategy Selection

```ts
// libs/realtime/strategies/selectStrategy.ts
export const selectRealtimeStrategy = (
  route: AppRoute,
): RealtimeStrategy | null => {
  switch (route) {
    case "Dashboard":
      return dashboardStrategy;
    case "Registration":
    case "ResumeRegistration":
      return registrationStrategy;
    default:
      return null;
  }
};
```

A pure function — no hooks, no side effects. Called inside the hook via `useMemo`, so the strategy reference only changes when the user navigates to a different scope. TypeScript will warn if a new route is added and this switch isn't updated.

### 5. Putting It All Together

```ts
// libs/realtime/useRealtimeConnection.ts
export const useRealtimeConnection = () => {
  const token = useAuthToken();
  const user = useCurrentUser();
  const route = useCurrentRoute();
  const { isInternet, isPushEnabled, isInForeground } = useConnectionState();

  const strategy = useMemo(() => selectRealtimeStrategy(route), [route]);
  const handler = useNotificationHandler(strategy?.scope ?? null);

  const subRef = useRef(null);

  useEffect(() => {
    if (!strategy) return;

    const shouldConnect = strategy.shouldConnect({
      token,
      user,
      isPushEnabled,
      isInForeground,
      isInternet,
    });

    if (!shouldConnect || !token) return;

    configureAmplify();
    let channel;

    const connectAndSubscribe = async () => {
      try {
        const endpoint = strategy.getEndpoint(user);
        const identifier = strategy.getIdentifier(user);
        console.log(`[Realtime] Connecting to ${strategy.scope} – ${identifier}`);

        channel = await events.connect(endpoint, { authToken: token });
        subRef.current = channel.subscribe({
          next: (data) => handler(data.event),
          error: (err) => console.error("[Realtime] Error:", err),
        });
      } catch (error) {
        console.error(`[Realtime] Connection failed for ${strategy.scope}`);
      }
    };

    connectAndSubscribe();

    return () => {
      subRef.current?.unsubscribe();
      subRef.current = null;
      channel?.close();
    };
  }, [token, user, isPushEnabled, isInForeground, isInternet, strategy, handler]);
};
```

Compare this to the original hook from the Problem section: the structure is identical. The hardcoded endpoint and inline guard condition moved into the strategy; event handling is now routed separately based on the selected scope via `useNotificationHandler`. The hook no longer knows anything about dashboards or registration — it just manages the connection.

---

## Is This Really Strategy?

This is worth pausing on, because the honest answer is: **partially**.

**Why it is more than just configuration:**
The strategies contain real decision logic. `shouldConnect` is not a static flag — it evaluates auth state, network state, foreground status, and push permission together. `getEndpoint` and `getIdentifier` encapsulate behavior that differs meaningfully between scopes. If you replaced them with a plain config object, that logic would have to move somewhere — most likely back into the hook, which is exactly what we were trying to avoid.

**Why it is not full classical Strategy:**
In the textbook GoF pattern, the strategy encapsulates the entire algorithm. Here, the hook still owns the lifecycle — connect, subscribe, clean up. The strategy only controls the _connection policy_: whether to connect, where, and who. Event handling is also routed externally via `scope` and `useNotificationHandler`, rather than being part of the strategy itself.

**The honest label:** this is a **Strategy/policy hybrid** — a pattern-inspired design that extracts variable policy from an invariant lifecycle, adapted to React's functional model rather than the class-based structure the original pattern assumed. That adaptation is intentional, not a shortcoming.

---

## The Result

**Before**: one hook, one hardcoded scope, no clear path to extend without duplication or conditionals.

**After**: a clean system where:

- The connection lifecycle is centralized in one hook
- Each scope's connection policy lives in its own strategy file
- Adding a new scope means a new strategy file and one new `case` — nothing else changes
- Each strategy is trivially testable: `expect(dashboardStrategy.shouldConnect({...})).toBe(true)`

When we later needed to add real-time connections for our customer support chat — different endpoint, different events, different auth — it took less than an hour. New strategy file, one new case in the selector, done.

**The trade-off is real though:** this design adds indirection. There's a selection layer, a type contract, and multiple files where one hook used to be. If you only ever have two scopes and no growth expected, this abstraction might cost more than it saves. Before reaching for this structure, ask: _is this variation expected to grow?_ In our case the answer was clear, but it won't always be.

---

## Key Takeaways

- **Recognize Duplication Early**: When you're about to copy-paste a hook with "just a few changes," pause and consider whether there's a pattern that fits.

- **Strategy Still Shines**: Despite being a "classic" pattern, Strategy remains useful in modern React for handling variations of the same algorithm.

- **Adapt Patterns to Your Context**: In React, strategies can be plain objects with typed method signatures — no classes, no factories, no hooks inside the strategy itself.

- **Extract Invariants**: The hook manages the connection lifecycle; `useConnectionState` owns the environmental signals; strategies encapsulate the variable connection policy. Each has one job.

- **Be Honest About What You've Built**: This isn't a full Strategy — it's a Strategy-style policy extraction. Knowing the difference helps you explain the design and judge when the same approach fits elsewhere.

- **Type Safety Pays Off**: TypeScript ensures all strategies follow the same contract. Adding a new strategy without satisfying the interface is a compile error, not a runtime surprise.

---

Thank you for your attention and happy hacking!
