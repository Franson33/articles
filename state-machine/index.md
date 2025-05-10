---
title: "I love finite-state machines"
date: 2025-05-10
tags: [patterns, state-machine, refactoring]
category: tech
draft: true
---

Hi, my name is Anton. I'm a software developer specializing in cross-platform mobile development, currently working at a fintech company where I help build a neo-banking application.

There’s often debate about design patterns—do we really need them, or are they just outdated theory with little practical value in modern software development? I strongly disagree with the idea that patterns are unnecessary. In my view, having a solid foundation in theoretical concepts is extremely valuable. It’s like recursion: you might not need it every day, but when you encounter a problem that is recursive in nature—like traversing a file system—you simply can’t solve it effectively any other way. The same applies to design patterns. Some processes naturally fit certain patterns, and recognizing them allows you to solve problems in a well-known, structured way. Otherwise, you risk reinventing the wheel—often with a less effective result.

Recently, I was assigned an interesting task at work that proves my point, and I think it’s worth sharing.

In my daily work, I’m always looking for patterns that can help implement features more cleanly and maintainably. Since I mostly work on the client side, which is inherently stateful, one of my favorite patterns is the finite-state machine. Even if you know nothing about state machines, you’re probably using them unconsciously in your code. The reason is that they occur very often and can be observed in many devices in modern society that perform a predetermined sequence of actions depending on a sequence of events. But if you use them unconsciously, they usually end up as a messy combination of boolean flags and if statements. It’s hard to add new states, and each additional state makes the abstraction worse and worse. It’s much better if you can recognize the pattern and organize it properly.

That’s exactly the situation we had. My team and I are pretty obsessed with code quality and are always trying to improve and refactor our codebase to make it more maintainable. During a regular upgrade of our dependencies, we decided to migrate to the latest version of React Navigation, and as part of that process, refactor some connected features. Like any banking app, a crucial part of ours is verifying customer identity and documents during onboarding. The original implementation, to be honest, was far from ideal. This is a fairly complex process, involving many steps, and in our app, it was spread across nine screens. Each component was treated as a separate entity, and the logic for each step was scattered throughout the component bodies—often 50 to 150 lines of business logic per component. All the data was passed through route params, which is fine for primitive values but definitely not the best option for complex objects.

---

**Before: Passing Everything Through Navigation Params**

<!-- CODE SNIPPET: before (component with lots of params and business logic) -->

Some screens didn’t need more than half of the params, but were forced to accept them because the next screen needed them. This is a direct violation of the interface segregation principle. It became almost impossible to track which screen actually needed which params. We could have continued treating it as nine separate screens, maybe refactored here and there, or moved some data from params to a state manager. That would have been a slight improvement, but still not what I wanted.

Instead, I decided to take a step back and look at the whole process from a wider perspective. I immediately noticed that it was really a single, complex process with nine steps—each of which could be represented as a separate state. This was a perfect case for the finite-state machine pattern!

I was excited to improve this feature, but the complexity made it hard to see the full picture. To help myself, I decided to visualize the process first. I spent about two days preparing a flowchart of the entire process, and only after that did I start working on the implementation.

---

## The Refactoring: Step by Step

I started by creating the structure of the state machine, declaring all the steps, and preparing a mapper function to connect each state to its corresponding screen.

<!-- CODE SNIPPET: FSM structure and step-to-screen mappers -->

I also wrote navigation helpers to handle the different navigation actions. Since React Navigation v7 requires the navigation object to come from a hook and only be used inside component bodies, I passed it to the state machine transition functions as a dependency.

<!-- CODE SNIPPET: navigation helpers and dependency injection -->

Once this preparation was done, I began gradually moving the business logic from each screen into the respective state in my state machine, step by step. This process took at least two weeks, including testing each step to make sure nothing broke. I also made a point not to change the logic itself, since it was already working well—there was no need to make the task even more complicated. I focused solely on changing the structure, making the transition as safe and minimal as possible.

---

## The Result

I was very satisfied with the result. Now, the business logic is encapsulated in one place, and it’s easy to understand the whole flow just by looking at the code for each step. In fact, it’s so clear and self-documenting that you barely need the flowchart anymore.

<!-- CODE SNIPPET: state machine structure after refactor -->

The screens themselves became much more “dumb”—they no longer handle any business logic, but simply use the functions provided by the state machine.

<!-- CODE SNIPPET: a screen after refactor, showing how simple it is -->

As a pleasant side effect, I was able to delete many lines of redundant code that were, in fact, not in use—but it wasn’t obvious before, and everyone was afraid to remove it for fear of breaking something. I shudder to think what it would have been like if we had needed to add new features or extend this code in its previous form—it would have been a nightmare. Now, the codebase is much better structured, clearer, far more maintainable, and easy to extend with new features in the future. And I haven’t even mentioned debugging: finding a bug in the old mess would have been terrifying, but now it’s so much easier.

---

Thank you for your attention and happy hacking!

