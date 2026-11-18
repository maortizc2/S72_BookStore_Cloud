import express from "express";

import { createBehaviorEvent } from "../controllers/eventController.js";

const router = express.Router();

router.post("/", createBehaviorEvent);

export default router;
