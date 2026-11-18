import express from "express";

import {
  getCurrentUser,
  login,
  logout,
} from "../controllers/authController.js";
import { authenticate } from "../middleware/authenticate.js";

const router = express.Router();

router.post("/login", login);
router.get("/me", authenticate, getCurrentUser);
router.post("/logout", logout);

export default router;
