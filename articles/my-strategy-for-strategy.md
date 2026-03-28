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

In our fintech app, like in many modern applications, push notifications are crucial for keeping users informed about important events—transactions, security alerts, account updates, and so on. But what happens when push notifications are disabled? Users still need to receive critical information in real-time.

We decided to implement a fallback mechanism using WebSocket connections with AWS Amplify Events API. The idea was simple: when push notifications are disabled, establish a real-time connection to receive events through an alternative channel.

The first implementation was straightforward. We added it for logged-in users in the main application scope—just a custom hook at the project root that handled everything:

```ts
// useRealtimeConnection.ts
import { events } from "aws-amplify/data";
import { useEffect, useRef, useState } from "react";
import { configureAmplify } from "@/services/amplify";

export const useRealtimeConnection = () => {
  const token = useAuthToken();
  const user = useCurrentUser();

  const [isInternet, setIsInternet] = useState(true);
  const [isPushEnabled, setIsPushEnabled] = useState(true);
  const [isInForeground, setIsInForeground] = useState(true);

  const subRef = useRef(null);

  const syncPushPermission = () =>
    getNotificationPermission().then(setIsPushEnabled);

  useEffect(() => {
    syncPushPermission();
  }, []);

  useAppInForeground(
    () => {
      setIsInForeground(true);
      syncPushPermission();
    },
    () => setIsInForeground(false),
  );

  useEffect(() => {
    const unsubscribe = subscribeToNetworkStatus(setIsInternet);
    return unsubscribe;
  }, []);

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
          next: (data) => onEvent(data.event),
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

This worked perfectly for the main app. We were happy with the solution and moved on to other tasks.

---

## The Plot Twist: Onboarding Needs It Too

A few weeks later, we had a new requirement: the onboarding flow also needed real-time event handling. Like every fintech app, our onboarding is very complicated and takes up maybe half of the application. During onboarding, users go through identity verification, document uploads, and various compliance checks—all of which can trigger real-time events that need to be communicated back to the user.

But here's the catch: the onboarding scope had different requirements:

- **Different endpoint** - onboarding events come from a separate service
- **Different events** - document verification status, compliance checks, not transactions
- **Different handlers** - onboarding-specific logic for processing events
- **Different auth state** - onboarding users hold a temporary session rather than a full account, so the connection preconditions are completely different
- **Different user identification** - session ID instead of user ID

My first thought was: "Well, I'll just create another hook, `useOnboardingRealtimeConnection`, copy the logic, and adjust it." But as soon as I started thinking about it, alarm bells went off in my head. This would be a textbook case of code duplication. Sure, the details differ, but the structure is identical:

1. Check if connection is needed
2. Establish connection with specific configuration
3. Subscribe to specific events
4. Handle cleanup

Creating a second hook felt like a poor solution and a pretty big code duplication. That was the exact moment I reached for my favorite topic—design patterns.

---

## Pattern Recognition: Enter the Strategy

The Strategy pattern is one of those classic patterns that remains useful in modern development. Here's the simple definition:

> **Strategy Pattern**: Define a family of algorithms, encapsulate each one, and make them interchangeable. Strategy lets the algorithm vary independently from clients that use it.

In everyday terms, think of it like choosing a payment method at checkout. Whether you pay with a credit card, PayPal, or Apple Pay, the checkout process remains the same—but the actual payment strategy changes. The cashier doesn't need to know the details of how each payment method works; they just need to know that each method can process a payment.

Another example: navigation apps. You can choose different routing strategies—fastest route, shortest route, avoid highways, avoid tolls. The app's interface stays the same, but the algorithm for calculating your route changes based on your chosen strategy.

In our case, this looked like a good fit for a Strategy-style refactor. The lifecycle algorithm — connect, subscribe, clean up — stays fixed in the hook. What varies is the **policy**: when to connect, which endpoint to use, how to identify the user. Extracting that variation into separate strategy objects would let the hook remain stable while each scope provides its own rules.

I'll come back to whether this is *really* Strategy in a moment. First, let me show the implementation.

---

## The Implementation: Step by Step

### 1. Folder Structure

First, I decided where this should live in our codebase. I created a new directory structure:

```
libs/
  realtime/
    strategies/
      types.ts
      dashboard.ts
      onboarding.ts
      selectStrategy.ts
      index.ts
    useRealtimeConnection.ts
```

This organization makes it clear that we're dealing with different strategies for the same concern—real-time connections.

### 2. Defining the Strategy Type

I started by defining what a "strategy" means in our context. This is the contract that all strategies must follow:

```ts
// libs/realtime/strategies/types.ts
import type { AppUser, AuthenticatedUser } from "@/types";

export type ConnectionParams = {
  token: string | null;
  user: AppUser | AuthenticatedUser;
  isPushEnabled: boolean;
  isInForeground: boolean;
  isInternet: boolean;
};

export type RealtimeStrategy = {
  scope: "main" | "onboarding";
  shouldConnect: (params: ConnectionParams) => boolean;
  getEndpoint: (user: AppUser | AuthenticatedUser) => string;
  getIdentifier: (user: AppUser | AuthenticatedUser) => string | number;
};
```

The `shouldConnect` method takes a `ConnectionParams` object — all the environmental signals the hook will collect and pass in. This keeps each strategy a pure, stateless object: no hidden state, no subscriptions, just a function that maps a snapshot of the world to a boolean. The `scope` field is a simple discriminator that lets the hook route incoming events to the right handler without the strategy needing to know anything about event processing itself.

### 3. Creating the Concrete Strategies

With the type defined, I could implement the two concrete strategies:

```ts
// libs/realtime/strategies/dashboard.ts
import { isAuthenticated } from "@/guards";
import type { RealtimeStrategy } from "./types";

export const dashboardStrategy: RealtimeStrategy = {
  scope: "main",
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
// libs/realtime/strategies/onboarding.ts
import { isAuthenticated } from "@/guards";
import type { RealtimeStrategy } from "./types";

export const onboardingStrategy: RealtimeStrategy = {
  scope: "onboarding",
  shouldConnect: ({ token, user, isPushEnabled, isInForeground, isInternet }) =>
    !isAuthenticated(user) &&
    token != null &&
    user.sessionId != null &&
    !isPushEnabled &&
    isInForeground &&
    isInternet,
  getEndpoint: (user) => {
    if (!user.sessionId) throw new Error("Session not available");
    return `/onboarding/${user.sessionId}/notifications`;
  },
  getIdentifier: (user) => user.sessionId ?? "unknown",
};
```

Both strategies follow the same contract but provide completely different implementations. The `isAuthenticated` type guard is what makes them mutually exclusive: the dashboard strategy only activates for a fully signed-in user, while the onboarding strategy activates for an unauthenticated session.

Also worth noting: `shouldConnect` receives not just auth/user data but also device-level signals like `isInForeground` and `isInternet`. In a mobile app these matter a lot — there's no point holding open a connection when the app is backgrounded or the device is offline, and the strategy is the right place to codify that decision.

### 4. Strategy Selection

Next, I needed a way to select which strategy to use based on the current navigation state. The key insight here is that this is a **pure function, not a hook**. It receives the current route as an argument and returns the matching strategy object — no side effects, no subscriptions, nothing:

```ts
// libs/realtime/strategies/selectStrategy.ts
import type { AppRoute } from "@/navigation";
import { dashboardStrategy } from "./dashboard";
import { onboardingStrategy } from "./onboarding";
import type { RealtimeStrategy } from "./types";

export const selectRealtimeStrategy = (
  route: AppRoute,
): RealtimeStrategy | null => {
  switch (route) {
    case "Main":
      return dashboardStrategy;
    case "Onboarding":
    case "ResumeOnboarding":
      return onboardingStrategy;
    default:
      return null;
  }
};
```

The `switch` on a typed navigation action (rather than string-matching a URL path) means TypeScript will warn us if we add a new route and forget to handle it here. Adding a third strategy later means adding one `case` and a new strategy file. Nothing else changes.

This function is called inside the hook via `useMemo`, so the strategy object only changes when the user navigates to a different scope.

### 5. Putting It All Together

Finally, the hook. The hook has **one responsibility**: managing the connection lifecycle. It collects all environmental state — token, user, push permission, foreground status, network connectivity — and hands it to the strategy. The strategy decides whether and how to connect:

```ts
// libs/realtime/useRealtimeConnection.ts
import { events } from "aws-amplify/data";
import { useEffect, useMemo, useRef, useState } from "react";
import { configureAmplify } from "@/services/amplify";
import { selectRealtimeStrategy } from "./strategies";
import { useAppInForeground } from "./state";
import { useNotificationHandler } from "./useNotificationHandler";

export const useRealtimeConnection = () => {
  const token = useAuthToken();
  const user = useCurrentUser();
  const route = useCurrentRoute();

  const [isInternet, setIsInternet] = useState(true);
  const [isPushEnabled, setIsPushEnabled] = useState(true);
  const [isInForeground, setIsInForeground] = useState(true);

  const strategy = useMemo(() => selectRealtimeStrategy(route), [route]);
  const handler = useNotificationHandler(strategy?.scope ?? null);

  const subRef = useRef(null);

  const syncPushPermission = () =>
    getNotificationPermission().then(setIsPushEnabled);

  useEffect(() => {
    syncPushPermission();
  }, []);

  useAppInForeground(
    () => {
      setIsInForeground(true);
      syncPushPermission();
    },
    () => setIsInForeground(false),
  );

  useEffect(() => {
    const unsubscribe = subscribeToNetworkStatus(setIsInternet);
    return unsubscribe;
  }, []);

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

        console.log(`[Realtime] Connecting ${strategy.scope} – ${identifier}`);

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

`useNotificationHandler` is a small hook that accepts a scope string and returns the matching event handler function. The hook knows nothing about dashboards or onboarding itself — `scope` is the only coupling between the lifecycle and the domain logic.

---

## Is This Really Strategy?

This is worth pausing on, because the honest answer is: **partially**.

**Why it is more than just configuration:**
The strategies contain real decision logic. `shouldConnect` is not a static flag — it evaluates auth state, network state, foreground state, and push permission status together to produce a boolean. `getEndpoint` and `getIdentifier` encapsulate behavior that differs meaningfully between scopes. If you replaced this with a plain config object, you'd need to move that logic somewhere else — the hook would have to know about authentication types and session IDs, exactly the coupling we were trying to avoid.

**Why it is not full classical Strategy:**
In the textbook GoF pattern, the strategy encapsulates the entire algorithm. Here, the hook still owns the lifecycle — connect, subscribe, clean up. The strategy only controls the *connection policy*: whether to connect, where, and who. Event handling is also routed externally via `scope` and `useNotificationHandler`, rather than being part of the strategy itself. A purist would call this a partial extraction.

**The honest label:** this is a **Strategy/policy hybrid** — a pattern-inspired design that extracts variable policy from an invariant lifecycle, adapted to fit React's functional model rather than the class-based structure the original pattern assumed.

That adaptation is intentional, not a shortcoming. Forcing a full class-based Strategy into a hooks-first codebase would add complexity without improving clarity. The goal was to isolate variation, not to satisfy a pattern checklist.

---

## The Result

**Before**: A single hook handling one scope — and no clear path to extend it without either duplicating the whole thing or tangling it with conditionals.

**After**: A clean, extensible system where:

- The connection lifecycle is centralized in one hook
- Different connection policies are encapsulated in separate strategies
- Adding a new connection type means creating a new strategy, not modifying existing code
- Each strategy is easy to test in isolation — a single function call with a mock object is all you need
- The hook stays focused on lifecycle management, regardless of how many strategies exist

The best part? When we later needed to add real-time connections for our customer support chat (yes, another different endpoint, different events, different auth), it took me less than an hour. I just created a new `supportChatStrategy.ts`, added it to the selection logic, and everything worked perfectly.

**The trade-off is real though:** this design introduces indirection. There's a selection layer, a type contract, and multiple files where one hook used to be. If you only ever have two cases and growth is unlikely, this abstraction might be more than the problem warrants. The question worth asking before reaching for this structure is: *is this variation expected to grow, or is it genuinely two fixed cases?* In our situation the answer was clear — but it won't always be.

---

## Key Takeaways

- **Recognize Code Duplication Early**: When you find yourself about to copy-paste a hook with "just a few changes," pause and consider if there's a pattern that fits.

- **Strategy Pattern Still Shines**: Despite being a "classic" pattern, Strategy remains useful in modern React development for handling variations of the same algorithm.

- **Adapt Patterns to Your Context**: You don't need to follow the textbook class-based implementation. In React, strategies can be plain objects with typed method signatures — no classes, no factories, no hooks inside the strategy itself.

- **Separation of Concerns**: The hook manages the connection lifecycle; strategies encapsulate the variable connection policy. Each has a single, clear responsibility.

- **Easy to Extend**: Adding new strategies doesn't require modifying existing code — just create a new strategy and update the selection logic.

- **Strategies Should Be Pure**: By receiving all inputs as parameters instead of closing over hook values, strategies stay framework-agnostic and trivially testable.

- **Be Honest About What You've Built**: This isn't a full Strategy — it's a Strategy-style policy extraction. Knowing the difference helps you explain the design to teammates and decide when the same approach fits elsewhere.

- **Type Safety**: TypeScript ensures all strategies follow the same contract, catching errors at compile time.

The Strategy pattern — even in this adapted form — helped us avoid code duplication, made our codebase more maintainable, and set us up for easy extension in the future. When you spot a situation where you need to do the same thing in different ways depending on context, think Strategy. Just be honest with yourself about how much of the pattern you actually need.

---

Thank you for your attention and happy hacking!
