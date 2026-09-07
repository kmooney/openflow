# OpenFlow: An open source wisprflow-like implementation

Openflow is a wisperflow like implementation that is open source and can be
installed by individuals in their home network or their own cloud provider.

Openflow is containerized, and allows users to "spin up" an openflow instance.

Openflow comes with clients for MacOS, Windows and iOS. The iOS implementation
comes with a keyboard plugin so users can speak to the openflow keyboard and get
formatted text instantly inserted into their text window.

OpenFlow also has an infrastructure to allow users to keep track of their
utterances, review them and delete them permanently, if desired.

## OpenFlow architecture

Openflow server runs on a run of the mill container. It's linux, probably
alpine. The server software is written in Rust. Openflow exposes a port to which
compressed audio is transmitted. The compressed audio is trasnmitted to an
inference provider (probably grok or amazon bedrock) who runs the whisper model on the
text input. The raw translated text is then sent to an LLM for further
formatting. The LLM removes "uhs," "ums" and other interstitial utterances,
formats numbered and bulleted lists, and adds appropriate punctuation, without
changing any of the text uttered by the user.

This final draft is then returned to the openflow jump server, and transmitted
back to the user.
