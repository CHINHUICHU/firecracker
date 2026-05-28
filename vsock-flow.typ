#import "@preview/typslides:1.3.3": *

// Project configuration
#show: typslides.with(
  ratio: "16-9",
  theme: "bluey",
  font: "Fira Sans",
  font-size: 20pt,
  link-style: "color",
  show-progress: true,
)

#slide(title: "Vsock Data Flow Architecture")[
  #set text(size: 15pt)
  #align(center)[
    #block(stroke: 1pt, inset: 1em, radius: 5pt, fill: luma(250))[
      #grid(
        columns: (1.2fr, 0.4fr, 2fr, 0.4fr, 1.2fr),
        align: horizon + center,
        column-gutter: 5pt,
        row-gutter: 15pt,
        
        [*GUEST SPACE*], [], [*FIRECRACKER (VMM)*], [], [*HOST SPACE*],
        
        // Layer 1: App/Sockets
        [#rect(fill: blue.lighten(90%), radius: 4pt, inset: 8pt)[Guest App \ (AF_VSOCK)]],
        [],
        [#rect(fill: gray.lighten(90%), radius: 4pt, inset: 8pt)[`event_handler.rs` \ (Epoll loop)]],
        [],
        [#rect(fill: green.lighten(90%), radius: 4pt, inset: 8pt)[Host App \ (AF_UNIX)]],

        // Layer 2: Queues/Parser
        [#rect(fill: blue.lighten(95%), radius: 4pt, inset: 8pt)[VirtIO Queues \ (RX / TX)]],
        [$arrow.l.r$],
        [#rect(fill: orange.lighten(80%), radius: 4pt, stroke: 1.5pt + orange, inset: 8pt)[`packet.rs` \ (The Shield / Parser)]],
        [$arrow.l.r$],
        [#rect(fill: green.lighten(95%), radius: 4pt, inset: 8pt)[Unix Domain \ Sockets]],

        // Layer 3: Logic
        [], [],
        [#rect(fill: orange.lighten(90%), radius: 4pt, inset: 8pt)[`connection.rs` \ (State & Credit Control)]],
        [], [],

        // Layer 4: Muxer
        [], [],
        [#rect(fill: orange.lighten(95%), radius: 4pt, inset: 8pt)[`muxer.rs` \ (Port Routing)]],
        [], []
      )
    ]
  ]

  #v(1em)
  #columns(2)[
    *TX Path (Guest $arrow$ Host):*
    1. Driver puts packet in TX Queue.
    2. `packet.rs` validates header/offsets.
    3. `connection.rs` checks credit.
    4. `muxer.rs` writes to host UDS.

    #colbreak()
    
    *RX Path (Host $arrow$ Guest):*
    1. `event_handler` detects UDS data.
    2. `muxer` routes data to Connection.
    3. `packet.rs` builds 44-byte header.
    4. Data pushed to Guest RX Queue.
  ]
]