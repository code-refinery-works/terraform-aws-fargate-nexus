#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { NetworkStack } from "../lib/network-stack";
import { DataStack } from "../lib/data-stack";
import { AppStack } from "../lib/app-stack";

const app = new cdk.App();

const env = (app.node.tryGetContext("env") as string) ?? "dev";
const project = (app.node.tryGetContext("project") as string) ?? "ecs-api";

const isProd = env === "prod";
const awsEnv = { account: process.env.CDK_DEFAULT_ACCOUNT, region: "ap-northeast-1" };

cdk.Tags.of(app).add("Environment", env);
cdk.Tags.of(app).add("Project", project);
cdk.Tags.of(app).add("ManagedBy", "AWS-CDK");

const network = new NetworkStack(app, `${project}-${env}-Network`, {
  env: awsEnv, project, envName: env, singleNatGw: !isProd,
});

const data = new DataStack(app, `${project}-${env}-Data`, {
  env: awsEnv, project, envName: env, isProd,
  vpc: network.vpc,
  isolatedSubnets: network.isolatedSubnets,
  ecsSecurityGroup: network.ecsSg,
});
data.addDependency(network);

const appStack = new AppStack(app, `${project}-${env}-App`, {
  env: awsEnv, project, envName: env, isProd,
  vpc: network.vpc,
  publicSubnets: network.publicSubnets,
  privateSubnets: network.privateSubnets,
  albSg: network.albSg,
  ecsSg: network.ecsSg,
  dbSecret: data.dbSecret,
  acmCertArn: app.node.tryGetContext("acmCertArn") as string,
  cfAcmCertArn: app.node.tryGetContext("cfAcmCertArn") as string,
  domainName: app.node.tryGetContext("domainName") as string,
  containerPort: Number(app.node.tryGetContext("containerPort") ?? 8080),
  taskCpu: Number(app.node.tryGetContext("taskCpu") ?? 512),
  taskMemory: Number(app.node.tryGetContext("taskMemory") ?? 1024),
});
appStack.addDependency(data);