import express from "express";

import {
  createOrder,
  getOrderById,
  getOrders,
} from "../controllers/orderController.js";
import { authenticate } from "../middleware/authenticate.js";

const router = express.Router();

router.get("/", authenticate, getOrders);
router.get("/:orderId", authenticate, getOrderById);
router.post("/", authenticate, createOrder);

export default router;
