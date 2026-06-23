# ── GraphQL API ───────────────────────────────────────────────────────────────

resource "aws_appsync_graphql_api" "todos" {
  name                = "${var.project_name}-api"
  authentication_type = "API_KEY"

  log_config {
    cloudwatch_logs_role_arn = aws_iam_role.appsync_logs.arn
    field_log_level          = var.log_level
    exclude_verbose_content  = true
  }

  schema = <<-GRAPHQL
    type Todo {
      id: ID!
      title: String!
      completed: Boolean!
    }

    type Query {
      getTodos: [Todo]
      getTodo(id: ID!): Todo
    }

    type Mutation {
      addTodo(title: String!): Todo
      updateTodo(id: ID!, completed: Boolean!): Todo
      deleteTodo(id: ID!): ID
    }

    schema {
      query: Query
      mutation: Mutation
    }
  GRAPHQL

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-api"
  })
}

# ── API Key ───────────────────────────────────────────────────────────────────

resource "aws_appsync_api_key" "main" {
  api_id  = aws_appsync_graphql_api.todos.id
  expires = var.api_key_expires
}

# ── DynamoDB Data Source ──────────────────────────────────────────────────────

resource "aws_appsync_datasource" "todos" {
  api_id           = aws_appsync_graphql_api.todos.id
  name             = "TodosDynamoDB"
  service_role_arn = aws_iam_role.appsync_dynamodb.arn
  type             = "AMAZON_DYNAMODB"

  dynamodb_config {
    table_name = aws_dynamodb_table.todos.name
    region     = var.aws_region
  }
}

# ── Resolvers ─────────────────────────────────────────────────────────────────

resource "aws_appsync_resolver" "get_todos" {
  api_id      = aws_appsync_graphql_api.todos.id
  type        = "Query"
  field       = "getTodos"
  data_source = aws_appsync_datasource.todos.name

  request_template  = <<-VTL
    {
      "version": "2018-05-29",
      "operation": "Scan"
    }
  VTL
  response_template = "$util.toJson($ctx.result.items)"
}

resource "aws_appsync_resolver" "get_todo" {
  api_id      = aws_appsync_graphql_api.todos.id
  type        = "Query"
  field       = "getTodo"
  data_source = aws_appsync_datasource.todos.name

  request_template = <<-VTL
    {
      "version": "2018-05-29",
      "operation": "GetItem",
      "key": {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id)
      }
    }
  VTL

  response_template = "$util.toJson($ctx.result)"
}

resource "aws_appsync_resolver" "add_todo" {
  api_id      = aws_appsync_graphql_api.todos.id
  type        = "Mutation"
  field       = "addTodo"
  data_source = aws_appsync_datasource.todos.name

  request_template = <<-VTL
    {
      "version": "2018-05-29",
      "operation": "PutItem",
      "key": {
        "id": { "S": "$util.autoId()" }
      },
      "attributeValues": {
        "title": { "S": "$ctx.args.title" },
        "completed": { "BOOL": false }
      }
    }
  VTL

  response_template = "$util.toJson($ctx.result)"
}

resource "aws_appsync_resolver" "update_todo" {
  api_id      = aws_appsync_graphql_api.todos.id
  type        = "Mutation"
  field       = "updateTodo"
  data_source = aws_appsync_datasource.todos.name

  request_template = <<-VTL
    {
      "version": "2018-05-29",
      "operation": "UpdateItem",
      "key": {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id)
      },
      "update": {
        "expression": "SET completed = :completed",
        "expressionValues": {
          ":completed": $util.dynamodb.toDynamoDBJson($ctx.args.completed)
        }
      },
      "condition": {
        "expression": "attribute_exists(id)"
      }
    }
  VTL

  response_template = "$util.toJson($ctx.result)"
}

resource "aws_appsync_resolver" "delete_todo" {
  api_id      = aws_appsync_graphql_api.todos.id
  type        = "Mutation"
  field       = "deleteTodo"
  data_source = aws_appsync_datasource.todos.name

  request_template = <<-VTL
    {
      "version": "2018-05-29",
      "operation": "DeleteItem",
      "key": {
        "id": $util.dynamodb.toDynamoDBJson($ctx.args.id)
      },
      "condition": {
        "expression": "attribute_exists(id)"
      }
    }
  VTL

  response_template = "$util.toJson($ctx.args.id)"
}
