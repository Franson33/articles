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
export const useRealtimeConnection = () => {
  const { userId, authToken } = useAuth();
  const isPushEnabled = usePushNotificationStatus();

  useEffect(() => {
    // Only connect when pushes are disabled
    if (isPushEnabled || !userId) return;

    const connection = amplify.events.connect({
      endpoint: "wss://api.app.com/events",
      token: authToken,
    });

    connection.on("transaction", handleTransaction);
    connection.on("security-alert", handleSecurityAlert);

    return () => connection.disconnect();
  }, [isPushEnabled, userId, authToken]);
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
- **Different authentication** - temporary session token instead of full auth token
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
      mainAppStrategy.ts
      onboardingStrategy.ts
      selectStrategy.ts
      index.ts
    useRealtimeConnection.ts
```

This organization makes it clear that we're dealing with different strategies for the same concern—real-time connections.

### 2. Defining the Strategy Type

I started by defining what a "strategy" means in our context. This is the contract that all strategies must follow:

```ts
// libs/realtime/strategies/types.ts
export type ConnectionConfig = {
  endpoint: string;
  token: string;
  userId?: string;
  sessionId?: string;
};

export type EventHandlers = {
  [eventName: string]: (data: any) => void;
};

export type RealtimeStrategy = {
  // Determines if this strategy should be active
  shouldConnect: () => boolean;

  // Provides connection configuration
  getConnectionConfig: () => ConnectionConfig;

  // Provides event handlers for this strategy
  getEventHandlers: () => EventHandlers;

  // Optional: strategy-specific cleanup
  onDisconnect?: () => void;
};
```

This type defines everything a strategy needs to provide: when to connect, how to connect, what events to handle, and how to clean up.

### 3. Creating the Concrete Strategies

With the type defined, I could now implement the two concrete strategies. First, the main app strategy:

```ts
// libs/realtime/strategies/mainAppStrategy.ts
import { useAuth } from "@/auth";
import { usePushNotificationStatus } from "@/notifications";
import { useAppStore } from "@/store";
import type { RealtimeStrategy } from "./types";

export const createMainAppStrategy = (): RealtimeStrategy => {
  const { userId, authToken } = useAuth();
  const isPushEnabled = usePushNotificationStatus();
  const { handleTransaction, handleSecurityAlert, handleAccountUpdate } =
    useAppStore();

  return {
    shouldConnect: () => {
      return !isPushEnabled && !!userId;
    },

    getConnectionConfig: () => ({
      endpoint: "wss://api.app.com/events",
      token: authToken,
      userId,
    }),

    getEventHandlers: () => ({
      transaction: handleTransaction,
      "security-alert": handleSecurityAlert,
      "account-update": handleAccountUpdate,
    }),
  };
};
```

And the onboarding strategy:

```ts
// libs/realtime/strategies/onboardingStrategy.ts
import { useOnboardingSession } from "@/onboarding";
import { usePushNotificationStatus } from "@/notifications";
import { useOnboardingStore } from "@/store";
import type { RealtimeStrategy } from "./types";

export const createOnboardingStrategy = (): RealtimeStrategy => {
  const { sessionId, sessionToken, isActive } = useOnboardingSession();
  const isPushEnabled = usePushNotificationStatus();
  const {
    handleDocumentVerification,
    handleComplianceCheck,
    handleIdentityStatus,
  } = useOnboardingStore();

  return {
    shouldConnect: () => {
      return !isPushEnabled && isActive && !!sessionId;
    },

    getConnectionConfig: () => ({
      endpoint: "wss://api.app.com/onboarding-events",
      token: sessionToken,
      sessionId,
    }),

    getEventHandlers: () => ({
      "document-verification": handleDocumentVerification,
      "compliance-check": handleComplianceCheck,
      "identity-status": handleIdentityStatus,
    }),
  };
};
```

Notice how both strategies follow the same contract but provide completely different implementations. The main app strategy uses `userId` and `authToken`, while the onboarding strategy uses `sessionId` and `sessionToken`. They connect to different endpoints and handle different events. Yet, from the outside, they look identical.

### 4. Strategy Selection

Next, I needed a way to choose which strategy to use based on the application state. This is where the context determines which algorithm to apply:

```ts
// libs/realtime/strategies/selectStrategy.ts
import { useLocation } from "@/navigation";
import { createMainAppStrategy } from "./mainAppStrategy";
import { createOnboardingStrategy } from "./onboardingStrategy";
import type { RealtimeStrategy } from "./types";

export const useRealtimeStrategy = (): RealtimeStrategy | null => {
  const location = useLocation();

  // Determine which strategy to use based on current app context
  const isOnboarding = location.pathname.startsWith("/onboarding");

  if (isOnboarding) {
    return createOnboardingStrategy();
  }

  // Check if user is authenticated for main app
  const { userId } = useAuth();
  if (userId) {
    return createMainAppStrategy();
  }

  // No strategy applicable
  return null;
};
```

This helper function encapsulates the decision logic. It checks the current route and authentication state to determine which strategy should be active. If we need to add a third strategy in the future—say, for a guest user experience—we just add another condition here.

### 5. Refactoring the Hook

Finally, I refactored the original hook to work with the generic strategy instead of hardcoded values. This is where the magic happens—the hook no longer knows or cares about the specifics of different connection types:

```ts
// libs/realtime/useRealtimeConnection.ts
import { useEffect, useRef } from "react";
import { amplify } from "@/services/amplify";
import { useRealtimeStrategy } from "./strategies";

export const useRealtimeConnection = () => {
  const strategy = useRealtimeStrategy();
  const connectionRef = useRef<Connection | null>(null);

  useEffect(() => {
    // No strategy means no connection needed
    if (!strategy) return;

    // Check if we should connect using the strategy
    if (!strategy.shouldConnect()) {
      // Disconnect if we have an active connection
      if (connectionRef.current) {
        connectionRef.current.disconnect();
        connectionRef.current = null;
      }
      return;
    }

    // Get configuration from the strategy
    const config = strategy.getConnectionConfig();
    const handlers = strategy.getEventHandlers();

    // Establish connection
    const connection = amplify.events.connect({
      endpoint: config.endpoint,
      token: config.token,
    });

    // Subscribe to events defined by the strategy
    Object.entries(handlers).forEach(([eventName, handler]) => {
      connection.on(eventName, handler);
    });

    connectionRef.current = connection;

    // Cleanup
    return () => {
      connection.disconnect();
      strategy.onDisconnect?.();
      connectionRef.current = null;
    };
  }, [strategy]);
};
```

Look at how clean this is! The hook doesn't know anything about main app vs. onboarding. It doesn't know about different endpoints, tokens, or event types. It just asks the strategy: "Should we connect? How should we connect? What events should we handle?" The strategy provides all the answers.

---

## The Result

I was very satisfied with the result. Now we have:

**Before**: Two separate hooks with duplicated logic, or a single hook with messy conditional logic scattered throughout.

**After**: A clean, extensible system where:

- The connection logic is centralized in one hook
- Different configurations are encapsulated in separate strategies
- Adding a new connection type means creating a new strategy, not modifying existing code
- Each strategy is easy to test in isolation
- The hook itself is simpler and more focused

The best part? When we later needed to add real-time connections for our customer support chat (yes, another different endpoint, different events, different auth), it took me less than an hour. I just created a new `supportChatStrategy.ts`, added it to the selection logic, and everything worked perfectly.

---

## Key Takeaways

- **Recognize Code Duplication Early**: When you find yourself about to copy-paste a hook or component with "just a few changes," pause and consider if there's a pattern that fits.

- **Strategy Pattern Still Shines**: Despite being a "classic" pattern, Strategy remains incredibly useful in modern React development for handling variations of the same algorithm.

- **Adapt Patterns to Your Context**: You don't need to follow the textbook class-based implementation. In React, strategies can be simple factory functions that return configuration objects.

- **Separation of Concerns**: The hook manages the connection lifecycle; strategies provide the configuration. Each has a single, clear responsibility.

- **Easy to Extend**: Adding new strategies doesn't require modifying existing code—just create a new strategy and update the selection logic.

- **Testability**: Each strategy can be tested independently, and the hook can be tested with mock strategies.

- **Type Safety**: TypeScript ensures all strategies follow the same contract, catching errors at compile time.

- **Self-Documenting**: The code structure itself communicates the intent—when you see the `strategies` folder, you immediately understand that there are multiple approaches to the same problem.

The Strategy pattern helped us avoid code duplication, made our codebase more maintainable, and set us up for easy extension in the future. When you spot a situation where you need to do the same thing in different ways depending on context, think Strategy—it might just be the perfect fit.

---

Thank you for your attention and happy hacking!
