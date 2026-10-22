# Architecture diagrams

Diagrams of the ECS deployment of `litellm-terraform-stack` as configured on the
`sandbox-deploy` branch (eu-west-1, CloudFront VPC origin to an internal ALB, Route 53 off in the sandbox). They are drawn from
the Terraform and middleware code, not from a live account. Drawn 2026-10-22.

| Diagram | What it shows |
|---|---|
| [`01-overview`](01-overview.png) | End-to-end request flow: clients → CloudFront → VPC origin → internal ALB with WAF → the Fargate task (middleware + LiteLLM) → Bedrock or external providers, plus RDS, Valkey and the regional services. |
| [`02-network`](02-network.png) | The VPC: two AZs, public and private /19 subnets, the internal ALB and CloudFront VPC-origin ENIs in the private subnets, single NAT, S3 gateway endpoint, conditional interface endpoints, route tables and the security-group chain. |
| [`03-request-routing`](03-request-routing.png) | ALB listener rules in priority order (middleware paths → :3000, everything else → :4000), the CloudFront secret header, the :443 listener, the admin-only `/key/generate` gate, and how master keys, virtual keys and Okta JWTs are handled. |
| [`04-sandbox-vs-production`](04-sandbox-vs-production.png) | Side by side: `envs/sandbox.env`, the settings `envs/production.env` changes, and production in its own AWS account (own domain with split certificates, SSO, 2–6 tasks, Multi-AZ RDS, 2 Valkey nodes). |

Each diagram is stored three ways:

- `<name>.excalidraw`: the editable source
- `<name>.png`: raster export, for READMEs and slides
- `<name>.svg`: vector export

![Overview](01-overview.png)

## Editing

1. Open the `.excalidraw` file in [excalidraw.com](https://excalidraw.com) (File → Open)
   or in VS Code with the
   [Excalidraw extension](https://marketplace.visualstudio.com/items?itemName=pomdtr.excalidraw-editor).
   The AWS icons are embedded in the file, so nothing else has to be installed.
2. Edit, then save the `.excalidraw` file.
3. Re-export the PNG and SVG with the same names (excalidraw.com: menu → Export image,
   background on, scale 1×) and commit all three files together.

## Conventions

The style follows the house style of the Bizibox diagrams repo:

- Helvetica throughout. Title 28 px, subtitle and legend 15 px, labels 11–13 px.
- Boxes: AWS account in grey (`#adb5bd` / `#f8f9fa`), VPC with an orange outline
  (`#f08c00`), public subnets in blue (`#1971c2` / `#e7f5ff`), private subnets in green
  (`#2f9e44` / `#ebfbee`). A dashed box means conditional, optional or scale-out only.
- Arrows are right-angled only. Red is the inference request path, grey is
  state, config, logs or egress. Numbered badges refer to the Flows box.
- Icons come from the official AWS Architecture Icons, via
  [stv-io/aws-excalidraw-icons](https://github.com/stv-io/aws-excalidraw-icons).

When the Terraform changes (ALB rules, subnets, sizing), update the matching diagram
and its date in the footer.
