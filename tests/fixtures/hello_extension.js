// Adou JS extension example.  Drop this file into .pi/extensions (project) or
// ~/.adou/agent/extensions (user) to make its commands, tools and event
// handlers visible to the agent runtime.
//
// The `adou` global (aliased as `pi`) is injected by the QuickJS runtime:
//   - adou.registerCommand({name, description, handler})
//   - adou.registerTool({name, label, description, parameters, handler})
//   - adou.on(event, handler)
//   - adou.emit(event, data)  (dispatches to handlers in the same context)
//
// Handler convention: tool arguments arrive as a JSON string; command
// handlers receive the raw argument string (everything after the command
// name).  The host serializes tool arguments with JSON.stringify and passes
// them to the handler as a single string argument; the handler may
// JSON.parse it.  Return values may be a JSON string, a {text: ...} object,
// or a Pi-style {content: [{type: 'text', text: ...}]} object.

let greetingCount = 0

adou.registerCommand({
  name: 'hello',
  description: 'Greet the user',
  handler: () => 'Hello from the JS extension',
})

adou.registerTool({
  name: 'add-numbers',
  label: 'Add Numbers',
  description: 'Sum two numbers',
  parameters: {
    type: 'object',
    properties: {
      a: { type: 'number', description: 'first addend' },
      b: { type: 'number', description: 'second addend' },
    },
    required: ['a', 'b'],
  },
  handler: (argsJson) => {
    const args = JSON.parse(argsJson)
    return args.a + args.b
  },
})

adou.on('greet', (eventJson) => {
  greetingCount += 1
})

adou.registerTool({
  name: 'greeting-count',
  label: 'Greeting Count',
  description: 'Number of greet events seen',
  handler: () => 'greetings=' + greetingCount,
})
