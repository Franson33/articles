---
title: "My strategy for Strategy"
date: 2025-11-20
tags: [patterns, strategy, refactoring, react]
category: tech
draft: true
---

Previously I already touched on the topic of design patterns. Today I want to continue this topic. Once more during my everyday work, I encountered a situation that perfectly illustrates the usage of one, and I think it's worth sharing.

Need to admit, many design patterns are really outdated and almost unusable in modern client-side code, React specifically. But there are a few of them that are still shining and, from my point of view, are just irreplaceable! These champions are the Finite State Machine (which I covered in my [previous article](/articles/i-love-state-machines)) and the Strategy pattern. Let me tell you about a recent case where Strategy saved the day.

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

The Strategy pattern is one of those classic patterns that remains incredibly useful in modern development. Here's the simple definition:

> **Strategy Pattern**: Define a family of algorithms, encapsulate each one, and make them interchangeable. Strategy lets the algorithm vary independently from clients that use it.

In everyday terms, think of it like choosing a payment method at checkout. Whether you pay with a credit card, PayPal, or Apple Pay, the checkout process remains the same—but the actual payment strategy changes. The cashier doesn't need to know the details of how each payment method works; they just need to know that each method can process a payment.

Another example: navigation apps. You can choose different routing strategies—fastest route, shortest route, avoid highways, avoid tolls. The app's interface stays the same, but the algorithm for calculating your route changes based on your chosen strategy.

In our case:

- **The algorithm family**: Different real-time connection configurations
- **The interchangeable strategies**: Main app connection vs. onboarding connection
- **The client**: Our hook that manages the connection lifecycle

This was a perfect case for the Strategy pattern! But its classical form with classes didn't make much sense in the context of React's mostly functional style code. So what I implemented was actually my free-form interpretation of it, adapted to work naturally with React hooks and functional components.

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

With the type defined, I could implement the two concrete strategies. Because strategies are **plain objects — not hooks, not factory functions** — they require zero framework magic:

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

And the onboarding strategy:

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

Notice how both strategies follow the same contract but provide completely different implementations. The `isAuthenticated` type guard is what makes them mutually exclusive: the dashboard strategy only activates for a fully signed-in user, while the onboarding strategy activates for an unauthenticated session. Neither strategy touches React at all — they are pure data objects you could test with a single `expect(dashboardStrategy.shouldConnect({...})).toBe(true)`.

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

The `switch` on a typed navigation action (rather than string-matching a URL path) means TypeScript will warn us if we add a new route and forget to handle it here. Adding a third strategy later — say, for a guest browsing mode — means adding one `case` and a new strategy file. Nothing else changes.

This function is called inside the hook via `useMemo`, so the strategy object only changes when the user navigates to a different scope.

### 5. Putting It All Together

Finally, the hook. This is where everything comes together. The hook has **one responsibility**: managing the connection lifecycle. It collects all environmental state — token, user, push permission, foreground status, network connectivity — and hands it to the strategy. The strategy decides what to do with it:

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

  // Pure function — returns a static strategy object, no hooks called inside
  const strategy = useMemo(() => selectRealtimeStrategy(route), [route]);

  // Scope-based handler routing: the hook knows *how* to connect, not *what* to do with events
  const handler = useNotificationHandler(strategy?.scope ?? null);

  const subRef = useRef(null);

  const syncPushPermission = () =>
    getNotificationPermission().then(setIsPushEnabled);

  useEffect(() => {
    syncPushPermission();
  }, []);

  // Re-check push permission whenever the app comes back to the foreground
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

    // Ensure Amplify is configured with the right credentials before connecting
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
  }, [
    token,
    user,
    isPushEnabled,
    isInForeground,
    isInternet,
    strategy,
    handler,
  ]);
};
```

`useNotificationHandler` is a small hook that accepts a scope string and returns the matching event handler function — a switch on `"main"` vs `"onboarding"` that maps to the right domain logic. The hook knows nothing about dashboards or onboarding itself. It collects context, hands it to the strategy, and the strategy decides everything else. The `scope` string is the only coupling between the two.

---

## The Result

I was very satisfied with the result. Now we have:

**Before**: A single hook handling one scope — and no clear path to extend it without either duplicating the whole thing or tangling it with conditionals.

**After**: A clean, extensible system where:

- The connection logic is centralized in one hook
- Different configurations are encapsulated in separate strategies
- Adding a new connection type means creating a new strategy, not modifying existing code
- Each strategy is easy to test in isolation
- The hook stays focused on lifecycle management, regardless of how many strategies exist

The best part? When we later needed to add real-time connections for our customer support chat (yes, another different endpoint, different events, different auth), it took me less than an hour. I just created a new `supportChatStrategy.ts`, added it to the selection logic, and everything worked perfectly.

---

## Key Takeaways

- **Recognize Code Duplication Early**: When you find yourself about to copy-paste a hook or component with "just a few changes," pause and consider if there's a pattern that fits.

- **Strategy Pattern Still Shines**: Despite being a "classic" pattern, Strategy remains incredibly useful in modern React development for handling variations of the same algorithm.

- **Adapt Patterns to Your Context**: You don't need to follow the textbook class-based implementation. In React, strategies can be plain objects with typed method signatures — no classes, no factories, no hooks inside the strategy itself.

- **Separation of Concerns**: The hook manages the connection lifecycle; strategies provide the configuration. Each has a single, clear responsibility.

- **Easy to Extend**: Adding new strategies doesn't require modifying existing code—just create a new strategy and update the selection logic.

- **Strategies Should Be Pure**: By receiving all inputs as parameters instead of closing over hook values, strategies stay framework-agnostic and trivially testable — a single function call with a mock object is all you need.

- **Type Safety**: TypeScript ensures all strategies follow the same contract, catching errors at compile time.

- **Self-Documenting**: The code structure itself communicates the intent—when you see the `strategies` folder, you immediately understand that there are multiple approaches to the same problem.

The Strategy pattern helped us avoid code duplication, made our codebase more maintainable, and set us up for easy extension in the future. When you spot a situation where you need to do the same thing in different ways depending on context, think Strategy—it might just be the perfect fit.

---

Thank you for your attention and happy hacking!
