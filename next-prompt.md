---
page: claude-chat
---
A chat interface for interacting with Claude, similar to a modern messaging app but tailored for terminal/server interactions.

**DESIGN SYSTEM (REQUIRED):**
- Platform: Mobile-first (Android)
- Theme: Support both Light and Dark, clean, technical
- Background: Light (#f5f6f8) / Dark (#101322)
- Primary Accent: Primary Blue (#0d33f2) for user bubbles and primary actions
- Text Primary: Slate-900 (Light) / Slate-100 (Dark)
- Typography: Space Grotesk font family
- Components: Gently rounded corners (12px for chat bubbles), clean inputs with left-inset icons

**Page Structure:**
1. **Header:** Top app bar showing "Claude" and current selected CD path (e.g., `/var/www/html/`) with a dropdown to change path. Button to select or create a new session.
2. **Chat Area:** Scrollable list of messages. User commands/prompts on the right (Primary Blue bubble), Claude responses on the left (Surface Light bubble).
3. **Quick Actions:** Below the last Claude message, show inline interactive buttons for "Yes", "Yes for All", and "No". 
4. **Input Area:** Bottom sticky area with a text input field for prompts and a send button (Primary icon).
5. **Bottom Navigation Bar:** Tabs for "Shell", "Connect", "Files", "Claude" (Claude active condition).
