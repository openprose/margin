# Margin field notes

Margin keeps the Markdown document authoritative while humans and agents discuss it.

## Architecture

The native editor launches without a browser runtime. The comment protocol stores durable textual anchors in the document itself.

The phrase shared boundary appears here. Later, the phrase shared boundary appears again.

## Open question

Should a synthesis attach to one passage, or to the whole document?

<!-- margin:comments:v1
{
  "@context" : [
    "http://www.w3.org/ns/anno.jsonld",
    {
      "margin" : "urn:margin:comments:v1:"
    }
  ],
  "id" : "urn:uuid:06b9ce2e\u002d769e\u002d45e6\u002dabed\u002d7b44f5d612c9#comments",
  "items" : [
    {
      "body" : {
        "format" : "text/markdown",
        "purpose" : "commenting",
        "type" : "TextualBody",
        "value" : "Keep this startup guarantee measurable."
      },
      "created" : "2026\u002d08\u002d16T03:55:11.782Z",
      "creator" : {
        "id" : "urn:margin:software:integration\u002dagent",
        "name" : "integration\u002dagent",
        "type" : "Software"
      },
      "generator" : {
        "id" : "urn:margin:app",
        "name" : "Margin",
        "type" : "Software"
      },
      "id" : "urn:uuid:11111111\u002d1111\u002d4111\u002d8111\u002d111111111111",
      "margin:status" : "open",
      "margin:statusModified" : "2026\u002d08\u002d16T03:55:11.782Z",
      "margin:statusModifiedBy" : {
        "id" : "urn:margin:software:integration\u002dagent",
        "name" : "integration\u002dagent",
        "type" : "Software"
      },
      "modified" : "2026\u002d08\u002d16T03:55:11.782Z",
      "motivation" : "commenting",
      "target" : {
        "selector" : [
          {
            "end" : 177,
            "start" : 129,
            "type" : "TextPositionSelector"
          },
          {
            "exact" : "native editor launches without a browser runtime",
            "prefix" : "scuss it.\n\n## Architecture\n\nThe ",
            "suffix" : ". The comment protocol stores du",
            "type" : "TextQuoteSelector"
          }
        ],
        "source" : {
          "format" : "text/markdown",
          "id" : "urn:uuid:06b9ce2e\u002d769e\u002d45e6\u002dabed\u002d7b44f5d612c9"
        },
        "type" : "SpecificResource"
      },
      "type" : "Annotation"
    },
    {
      "body" : {
        "format" : "text/markdown",
        "type" : "TextualBody",
        "value" : "Agreed; add a warm\u002dlaunch p95 gate."
      },
      "created" : "2026\u002d08\u002d16T03:55:11.974Z",
      "creator" : {
        "id" : "urn:margin:person:reviewer",
        "name" : "Reviewer",
        "type" : "Person"
      },
      "generator" : {
        "id" : "urn:margin:app",
        "name" : "Margin",
        "type" : "Software"
      },
      "id" : "urn:uuid:22222222\u002d2222\u002d4222\u002d8222\u002d222222222222",
      "modified" : "2026\u002d08\u002d16T03:55:11.974Z",
      "motivation" : "replying",
      "target" : "urn:uuid:11111111\u002d1111\u002d4111\u002d8111\u002d111111111111",
      "type" : "Annotation"
    }
  ],
  "margin:contentByteLength" : 433,
  "margin:contentSha256" : "sha256:812b179a7752cd38c912dba82fb017a9b6514cbf2cbdcee5df68d0a2433908db",
  "margin:document" : {
    "format" : "text/markdown",
    "id" : "urn:uuid:06b9ce2e\u002d769e\u002d45e6\u002dabed\u002d7b44f5d612c9"
  },
  "margin:projection" : "markdown\u002dsource\u002dv1",
  "margin:revision" : 2,
  "margin:version" : 1,
  "modified" : "2026\u002d08\u002d16T03:55:11.974Z",
  "partOf" : {
    "id" : "urn:uuid:06b9ce2e\u002d769e\u002d45e6\u002dabed\u002d7b44f5d612c9#collection",
    "total" : 2,
    "type" : "AnnotationCollection"
  },
  "type" : "AnnotationPage"
}
-->
